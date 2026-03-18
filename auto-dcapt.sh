#!/bin/bash
set -euo pipefail

# ==========================================
# USAGE:
#   ./auto-dcapt.sh apps/lxp.conf              # Full run (deploy + all tests)
#   ./auto-dcapt.sh apps/lxp.conf --skip-to 2  # Resume from step 2 (Run 1)
#
# STEPS:
#   0 = Configure tfvars
#   1 = Deploy cluster
#   2 = Run 1: Baseline test
#   3 = Wait for Jira + App install + reindex
#   4 = Wait for Jira (reindex recovery) + screenshot
#   5 = Run 2: Passive test + perf report
#   6 = Inject test data + sync tests + Run 3: Active test (1-node)
#   7 = Run 4: Scale test (2-node)
#   8 = Run 5: Scale test (4-node)
#   9 = Generate scale report
#   10 = Terminate cluster
# ==========================================
if [ -z "${1:-}" ]; then
  echo "Usage: $0 <app-config-file> [--skip-to <step>]"
  echo "Example: $0 apps/lxp.conf"
  echo "Example: $0 apps/lxp.conf --skip-to 2"
  echo ""
  echo "Available configs:"
  ls -1 apps/*.conf 2>/dev/null || echo "  (none found in apps/)"
  exit 1
fi

APP_CONF="$1"
if [ ! -f "$APP_CONF" ]; then
  echo "ERROR: Config file '$APP_CONF' not found."
  exit 1
fi

# Parse --skip-to flag
SKIP_TO=0
if [ "${2:-}" = "--skip-to" ] && [ -n "${3:-}" ]; then
  SKIP_TO="$3"
  echo ">>> Resuming from step $SKIP_TO (skipping steps 0-$((SKIP_TO - 1)))"
fi

# ==========================================
# LOAD APP CONFIG
# ==========================================
echo ">>> Loading app config from: $APP_CONF"
source "$APP_CONF"

# Validate required fields
for var in APP_NAME APP_BRANCH APP_JAR_PATH APP_LICENSE STANDALONE_EXTENSION; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: Required field '$var' is missing in $APP_CONF"
    exit 1
  fi
done

# ==========================================
# GLOBAL CONFIGURATION
# ==========================================
export ENVIRONMENT_NAME="dcapt-${APP_NAME}"
export REGION="us-east-2"

# Resolve absolute path to toolkit root (where this script lives)
TOOLKIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Platform-aware sed in-place: macOS needs '' backup arg, Linux does not
if [[ "$OSTYPE" == "darwin"* ]]; then
  sedi() { sed -i '' "$@"; }
else
  sedi() { sed -i "$@"; }
fi

TFVARS_FILE="$TOOLKIT_ROOT/app/util/k8s/dcapt.tfvars"
JIRA_YML="$TOOLKIT_ROOT/app/jira.yml"
PERF_PROFILE="$TOOLKIT_ROOT/app/reports_generation/performance_profile.yml"
SCALE_PROFILE="$TOOLKIT_ROOT/app/reports_generation/scale_profile.yml"
INSTALL_LOG="$TOOLKIT_ROOT/install.log"

# Jira Credentials (override via env vars if needed)
ADMIN_USER="${DCAPT_ADMIN_USER:-admin}"
ADMIN_PASS="${DCAPT_ADMIN_PASS:-admin}"

# Map config values to script variables
APP_FILE_PATH="$APP_JAR_PATH"
APP_TESTS_BRANCH="$APP_BRANCH"
MY_CUSTOM_JQL="${CUSTOM_JQL:-project = TEST ORDER BY created DESC}"

# Jira Data Center License (for Terraform infrastructure)
JIRA_LICENSE="${DCAPT_JIRA_LICENSE:-AAAB2g0ODAoPeNqVUttu2kAUfPdXWOpL+mDqtbkkSJYKi0nc+gYmKYn6sjGHsI2xreO1W+fr4wsIWghSH3d2d+bMnPk0RS47DGWiy2pv2NOHelemk4WsqVpfoghM8CSeMAFGjSiqrhBdsnkIcQaLMgWXbcGgnuOYc2qNbOkXR9bZ3ZsrXv82THdhzv25FZiSm2+fAb31fQaYGQrZU5l/Uo7lkU5XIVpLlmKyykPRqQ9KlqzFb4bQYaHgBRgCc5CC/DkLkaeNWIOYBYtydjg3RBU7oxALwBaMWuk7lm0Mh3bpdEZvg3jwo1ihP+vh9ElsH0f+m57079j3mfUwsiz+ZUkX5GkZsXugZcR9EaXjYtAf731YE8O2JoHpKrZGuhq5Ib1LLgLBsJ5nzaKs8gFYAFYU46WqKTePHlEs97qv2F7vVnqF8qHKrLZE+qo6UK91nUgvCBBvkjQFvJC6n2O4YRn8u8fj300wKfJsH6rpGn/7OKN1rgETOCzjmzUfycHOrXxVb0BuV/D551A+bElyGK/QmMXh/1fhpFPHgx735ALHB93YJ65JHr6wmGdtp9I8euXia1KZ3PK3BMtOmGwlmsSikjMrL9EHT5oJTuZt0JNBL0S8U2rg80LvXUdTrDAtAhUAj+Wif6SCaV9j7bP2HRTqbhPnY4YCFC2zeP28ru1qxrRZlq/NU11dyfwhX02mi}"

echo ">>> App: $APP_NAME | Branch: $APP_BRANCH | Standalone: $STANDALONE_EXTENSION"

# Helper: get latest results directory
get_latest_results() {
  local dir
  dir=$(ls -td "$TOOLKIT_ROOT/app/results/jira"/*/ 2>/dev/null | head -1 | xargs -I{} basename {})
  if [ -z "$dir" ]; then
    echo "ERROR: No results directory found after test run." >&2
    exit 1
  fi
  echo "$dir"
}

# Helper: run bzt test on pod (uses --no-tmux for non-interactive servers)
# Always runs from TOOLKIT_ROOT regardless of current directory
run_bzt() {
  cd "$TOOLKIT_ROOT" || exit 1
  docker run --pull=always --env-file "$TOOLKIT_ROOT/app/util/k8s/aws_envs" \
    -e "REGION=$REGION" -e "ENVIRONMENT_NAME=$ENVIRONMENT_NAME" \
    -v "$TOOLKIT_ROOT:/data-center-terraform/dc-app-performance-toolkit" \
    -v "$TOOLKIT_ROOT/app/util/k8s/bzt_on_pod.sh:/data-center-terraform/bzt_on_pod.sh" \
    atlassianlabs/terraform:2.9.15 bash bzt_on_pod.sh jira.yml --no-tmux
}

echo "=== Starting Full 5-Run DCAPT Zero-Touch Pipeline ==="

# If resuming, extract the existing URL from jira.yml (only the config line, not jmeter variable ref)
if [ "$SKIP_TO" -gt 1 ]; then
  EXTRACTED_URL=$(grep 'application_hostname:.*# Jira DC hostname' "$JIRA_YML" | awk '{print $2}' | tr -d ' ')
  if [ -z "$EXTRACTED_URL" ] || [[ "$EXTRACTED_URL" == *'${'* ]] || [[ "$EXTRACTED_URL" == "test_jira_instance"* ]]; then
    echo "ERROR: Cannot resume — no valid hostname found in jira.yml. Run full pipeline first or set it manually."
    exit 1
  fi
  echo ">>> Using existing Jira Hostname: $EXTRACTED_URL"
fi

# ==========================================
# 0. CONFIGURE TFVARS (Product & License)
# ==========================================
if [ "$SKIP_TO" -le 0 ]; then
  echo ">>> Configuring dcapt.tfvars for Jira deployment..."

  # Set product to jira (idempotent - matches any current value)
  sedi 's/^products = .*/products = ["jira"]/' "$TFVARS_FILE"

  # Set environment name (idempotent)
  sedi "s/^environment_name = .*/environment_name = \"$ENVIRONMENT_NAME\"/" "$TFVARS_FILE"

  # Set jira license (idempotent)
  sedi "s|^jira_license = .*|jira_license = \"$JIRA_LICENSE\"|" "$TFVARS_FILE"

  echo ">>> tfvars configured: product=jira, environment=$ENVIRONMENT_NAME"
else
  echo ">>> Skipping step 0: Configure tfvars"
fi

# ==========================================
# 1. INITIAL INSTALLATION (1-NODE)
# ==========================================
if [ "$SKIP_TO" -le 1 ]; then
  echo ">>> Deploying 1-Node Cluster..."
  cd "$TOOLKIT_ROOT/app/util/k8s" || exit 1

  # Run installation and pipe output to a log file to extract the URL
  docker run --pull=always --env-file aws_envs \
    -v "/$PWD/dcapt.tfvars:/data-center-terraform/conf.tfvars" \
    -v "/$PWD/dcapt-snapshots.json:/data-center-terraform/dcapt-snapshots.json" \
    -v "/$PWD/logs:/data-center-terraform/logs" \
    atlassianlabs/terraform:2.9.15 ./install.sh -c conf.tfvars | tee "$INSTALL_LOG"

  # Extract the AWS ELB Hostname from the console output log (strip ANSI codes)
  EXTRACTED_URL=$(sed 's/\x1b\[[0-9;]*m//g' "$INSTALL_LOG" | grep -oE "[a-zA-Z0-9.-]+\.elb\.amazonaws\.com" | head -1)

  if [ -z "$EXTRACTED_URL" ]; then
      echo "ERROR: Could not extract Jira URL from Terraform output. Exiting."
      exit 1
  fi
  echo ">>> Extracted Jira Hostname: $EXTRACTED_URL"

  cd "$TOOLKIT_ROOT" || exit 1

  # Update jira.yml with the new hostname
  echo ">>> Updating jira.yml with new hostname..."
  sedi "s|application_hostname:.*# Jira DC hostname.*|application_hostname: $EXTRACTED_URL   # Jira DC hostname|" "$JIRA_YML"
else
  echo ">>> Skipping step 1: Deploy cluster"
fi

# ==========================================
# 2. RUN 1: PERFORMANCE REGRESSION (BASELINE)
# ==========================================
if [ "$SKIP_TO" -le 2 ]; then
  echo ">>> Starting Run 1: Baseline Test (No App)..."
  run_bzt
else
  echo ">>> Skipping step 2: Run 1 baseline test"
fi

RUN1_DIR=""
if [ "$SKIP_TO" -le 2 ]; then
  RUN1_DIR=$(get_latest_results) || true
fi

# ==========================================
# 3. APP INSTALL + TRIGGER REINDEX
# ==========================================
if [ "$SKIP_TO" -le 3 ]; then
  # Wait for Jira to be available before proceeding
  echo ">>> Waiting for Jira to be available..."
  JIRA_WAIT=0
  while true; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$EXTRACTED_URL/jira/status" || true)
    if [ "$HTTP_CODE" = "200" ]; then
      echo ">>> Jira is up (HTTP 200)."
      break
    fi
    JIRA_WAIT=$((JIRA_WAIT + 1))
    if [ "$JIRA_WAIT" -ge 120 ]; then
      echo "ERROR: Jira not available after 2 hours. Exiting."
      exit 1
    fi
    echo ">>> Jira not ready (HTTP $HTTP_CODE). Retrying in 60s... ($JIRA_WAIT/120)"
    sleep 60
  done

  echo ">>> Automating App Installation via UPM REST API..."
  UPM_HEADERS=$(curl -s -u "$ADMIN_USER:$ADMIN_PASS" -D- -o /dev/null "http://$EXTRACTED_URL/jira/rest/plugins/1.0/" || true)
  TOKEN=$(echo "$UPM_HEADERS" | grep -i 'upm-token' | awk '{print $2}' | tr -d '\r\n' || true)

  if [ -z "$TOKEN" ]; then
    echo "ERROR: Failed to retrieve UPM token. Check Jira availability and credentials."
    echo "DEBUG: Response headers:"
    echo "$UPM_HEADERS"
    exit 1
  fi
  echo ">>> UPM Token acquired: $TOKEN"

  curl -s -u "$ADMIN_USER:$ADMIN_PASS" \
    -X POST \
    -H "Accept: application/json" \
    -F "plugin=@$APP_FILE_PATH" \
    "http://$EXTRACTED_URL/jira/rest/plugins/1.0/?token=$TOKEN"

  echo ">>> Waiting 60 seconds for the app to initialize..."
  sleep 60

  echo ">>> Triggering Foreground Lucene Re-Index via REST API..."
  curl -s -u "$ADMIN_USER:$ADMIN_PASS" \
    -X POST \
    -H "Content-Type: application/json" \
    "http://$EXTRACTED_URL/jira/rest/api/2/reindex?type=FOREGROUND"
  echo ">>> Re-index triggered."
else
  echo ">>> Skipping step 3: App install + reindex trigger"
fi

# ==========================================
# 4. WAIT FOR JIRA (REINDEX RECOVERY) + SCREENSHOT
# ==========================================
if [ "$SKIP_TO" -le 4 ]; then
  echo ">>> Waiting for Jira to come back online (reindex may take a while)..."
  JIRA_WAIT=0
  while true; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$EXTRACTED_URL/jira/status" || true)
    if [ "$HTTP_CODE" = "200" ]; then
      echo ">>> Jira is up (HTTP 200)."
      break
    fi
    JIRA_WAIT=$((JIRA_WAIT + 1))
    if [ "$JIRA_WAIT" -ge 120 ]; then
      echo "ERROR: Jira not available after 2 hours. Exiting."
      exit 1
    fi
    echo ">>> Jira not ready (HTTP $HTTP_CODE). Checking again in 60s... ($JIRA_WAIT/120)"
    sleep 60
  done

  echo ">>> Setting up Playwright to capture the mandatory screenshot..."
  PLAYWRIGHT_DIR="$TOOLKIT_ROOT/playwright-tools"
  mkdir -p "$PLAYWRIGHT_DIR" && cd "$PLAYWRIGHT_DIR" || exit 1
  npm init -y > /dev/null 2>&1
  npm install playwright || { echo "ERROR: playwright install failed"; exit 1; }
  npx playwright install chromium --with-deps || { echo "ERROR: chromium install failed"; exit 1; }

  cat << 'EOF' > capture.js
const { chromium } = require('playwright');
(async () => {
  const url = process.argv[2];
  const user = process.argv[3];
  const pass = process.argv[4];

  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await context.newPage();

  console.log("Navigating to Jira Login...");
  await page.goto(`http://${url}/jira/login.jsp`);
  await page.fill('#login-form-username', user);
  await page.fill('#login-form-password', pass);
  await page.click('#login-form-submit');
  await page.waitForLoadState('networkidle');

  console.log("Navigating to Index Admin Page...");
  await page.goto(`http://${url}/jira/secure/admin/jira/IndexAdmin.jspa`);
  await page.waitForLoadState('networkidle');

  if (await page.locator('#login-form-authenticatePassword').isVisible()) {
      console.log("WebSudo prompt detected. Entering admin password again...");
      await page.fill('#login-form-authenticatePassword', pass);
      await page.click('#authenticateButton');
      await page.waitForLoadState('networkidle');
  }

  console.log("Taking full page screenshot...");
  await page.screenshot({ path: '../lucene_reindex_screenshot.png', fullPage: true });

  await browser.close();
})();
EOF

  node capture.js "$EXTRACTED_URL" "$ADMIN_USER" "$ADMIN_PASS"
  cd "$TOOLKIT_ROOT" || exit 1
  rm -rf "$PLAYWRIGHT_DIR"
  echo ">>> Screenshot saved successfully as 'lucene_reindex_screenshot.png'!"
else
  echo ">>> Skipping step 4: Wait for Jira + screenshot"
fi

# ==========================================
# 5. RUN 2: PASSIVE OVERHEAD TEST
# ==========================================
if [ "$SKIP_TO" -le 5 ]; then
  echo ">>> Starting Run 2: Passive Test (App installed, no custom actions)..."
  run_bzt

  RUN2_DIR=$(get_latest_results)

  echo ">>> Generating Performance Regression Report..."
  # If RUN1_DIR is empty (skipped), grab second-latest results dir
  if [ -z "$RUN1_DIR" ]; then
    RUN1_DIR=$(ls -td "$TOOLKIT_ROOT/app/results/jira"/*/ 2>/dev/null | sed -n '2p' | xargs -I{} basename {})
  fi
  sedi "s|relativePath:.*# Run 1|relativePath: \"../results/jira/$RUN1_DIR\" # Run 1|g" "$PERF_PROFILE"
  sedi "s|relativePath:.*# Run 2|relativePath: \"../results/jira/$RUN2_DIR\" # Run 2|g" "$PERF_PROFILE"

  docker run --pull=always -v "/$PWD:/dc-app-performance-toolkit" \
    --workdir="//dc-app-performance-toolkit/app/reports_generation" \
    --entrypoint="python" \
    atlassian/dcapt csv_chart_generator.py performance_profile.yml
else
  echo ">>> Skipping step 5: Run 2 passive test + perf report"
fi

# ==========================================
# 6. TEST DATA INJECTION + SYNC TESTS + RUN 3: SCALABILITY (1-NODE, ACTIVE)
# ==========================================
if [ "$SKIP_TO" -le 6 ]; then
  echo ">>> Injecting test data for Custom JQL..."
  curl -s -o /dev/null -u "$ADMIN_USER:$ADMIN_PASS" \
    -X POST -H "Content-Type: application/json" \
    -d '{"key": "TEST", "name": "Custom JQL Test Project", "projectTypeKey": "software", "lead": "'"$ADMIN_USER"'", "assigneeType": "PROJECT_LEAD"}' \
    "http://$EXTRACTED_URL/jira/rest/api/2/project"

  sleep 5

  curl -s -o /dev/null -u "$ADMIN_USER:$ADMIN_PASS" \
    -X POST -H "Content-Type: application/json" \
    -d '{"issueUpdates": [
          {"fields": {"project": {"key": "TEST"}, "summary": "Automated Custom JQL Issue 1", "issuetype": {"name": "Task"}}},
          {"fields": {"project": {"key": "TEST"}, "summary": "Automated Custom JQL Issue 2", "issuetype": {"name": "Task"}}},
          {"fields": {"project": {"key": "TEST"}, "summary": "Automated Custom JQL Issue 3", "issuetype": {"name": "Task"}}}
        ]}' \
    "http://$EXTRACTED_URL/jira/rest/api/2/issue/bulk"
  echo ">>> Test data successfully injected!"

  echo ">>> Syncing custom JMeter and Selenium tests from branch: $APP_TESTS_BRANCH..."
  GIT_REMOTE=$(git remote | head -1)
  git fetch "$GIT_REMOTE"
  git checkout "$GIT_REMOTE/$APP_TESTS_BRANCH" -- app/jmeter/ app/selenium_ui/ || {
    echo "ERROR: Failed to sync custom tests from branch $APP_TESTS_BRANCH on remote $GIT_REMOTE"; exit 1;
  }

  echo ">>> Modifying jira.yml to enable the newly synced App-Specific Tests..."
  sedi "s/standalone_extension: .*/standalone_extension: $STANDALONE_EXTENSION/" "$JIRA_YML"
  sedi "s/# test_1_custom_action/test_1_custom_action/" "$JIRA_YML"
  sedi "s/# test_1_selenium_custom_action/test_1_selenium_custom_action/" "$JIRA_YML"
  sedi "s|custom_jql:.*|custom_jql: \"$MY_CUSTOM_JQL\"|" "$JIRA_YML"

  echo ">>> Starting Run 3: Active Test with synced tests enabled..."
  run_bzt

  RUN3_DIR=$(get_latest_results)
else
  echo ">>> Skipping step 6: Test data + sync + Run 3"
fi

# ==========================================
# 7. RUN 4: SCALABILITY (2-NODE)
# ==========================================
if [ "$SKIP_TO" -le 7 ]; then
  echo ">>> Scaling cluster to 2 Nodes..."
  sedi "s/^jira_replica_count *= *.*/jira_replica_count = 2/" "$TFVARS_FILE"

  cd "$TOOLKIT_ROOT/app/util/k8s" || exit 1
  docker run --pull=always --env-file aws_envs \
    -v "/$PWD/dcapt.tfvars:/data-center-terraform/conf.tfvars" \
    -v "/$PWD/dcapt-snapshots.json:/data-center-terraform/dcapt-snapshots.json" \
    -v "/$PWD/logs:/data-center-terraform/logs" \
    atlassianlabs/terraform:2.9.15 ./install.sh -c conf.tfvars
  cd "$TOOLKIT_ROOT" || exit 1

  echo ">>> Starting Run 4: 2-Node Scale Test..."
  run_bzt

  RUN4_DIR=$(get_latest_results)
else
  echo ">>> Skipping step 7: Run 4 (2-node)"
fi

# ==========================================
# 8. RUN 5: SCALABILITY (4-NODE)
# ==========================================
if [ "$SKIP_TO" -le 8 ]; then
  echo ">>> Scaling cluster to 4 Nodes..."
  sedi "s/^jira_replica_count *= *.*/jira_replica_count = 4/" "$TFVARS_FILE"

  cd "$TOOLKIT_ROOT/app/util/k8s" || exit 1
  docker run --pull=always --env-file aws_envs \
    -v "/$PWD/dcapt.tfvars:/data-center-terraform/conf.tfvars" \
    -v "/$PWD/dcapt-snapshots.json:/data-center-terraform/dcapt-snapshots.json" \
    -v "/$PWD/logs:/data-center-terraform/logs" \
    atlassianlabs/terraform:2.9.15 ./install.sh -c conf.tfvars
  cd "$TOOLKIT_ROOT" || exit 1

  echo ">>> Starting Run 5: 4-Node Scale Test..."
  run_bzt

  RUN5_DIR=$(get_latest_results)
else
  echo ">>> Skipping step 8: Run 5 (4-node)"
fi

# ==========================================
# 9. GENERATE SCALABILITY REPORT
# ==========================================
if [ "$SKIP_TO" -le 9 ]; then
  echo ">>> Generating Scale Report..."
  # If RUN3/4/5 dirs are empty (skipped earlier), grab from existing results
  results_dirs=($(ls -td "$TOOLKIT_ROOT/app/results/jira"/*/ 2>/dev/null | head -3))
  RUN5_DIR="${RUN5_DIR:-$(basename "${results_dirs[0]:-}")}"
  RUN4_DIR="${RUN4_DIR:-$(basename "${results_dirs[1]:-}")}"
  RUN3_DIR="${RUN3_DIR:-$(basename "${results_dirs[2]:-}")}"

  sedi "s|relativePath:.*# 1 Node|relativePath: \"../results/jira/$RUN3_DIR\" # 1 Node|g" "$SCALE_PROFILE"
  sedi "s|relativePath:.*# 2 Nodes|relativePath: \"../results/jira/$RUN4_DIR\" # 2 Nodes|g" "$SCALE_PROFILE"
  sedi "s|relativePath:.*# 4 Nodes|relativePath: \"../results/jira/$RUN5_DIR\" # 4 Nodes|g" "$SCALE_PROFILE"

  docker run --pull=always -v "/$PWD:/dc-app-performance-toolkit" \
    --workdir="//dc-app-performance-toolkit/app/reports_generation" \
    --entrypoint="python" \
    atlassian/dcapt csv_chart_generator.py scale_profile.yml
else
  echo ">>> Skipping step 9: Scale report"
fi

# ==========================================
# 10. TERMINATE CLUSTER
# ==========================================
if [ "$SKIP_TO" -le 10 ]; then
  echo ">>> Terminating cluster (graceful uninstall)..."
  cd "$TOOLKIT_ROOT/app/util/k8s" || exit 1

  docker run --pull=always --env-file aws_envs \
    -v "/$PWD/dcapt.tfvars:/data-center-terraform/conf.tfvars" \
    -v "/$PWD/dcapt-snapshots.json:/data-center-terraform/dcapt-snapshots.json" \
    -v "/$PWD/logs:/data-center-terraform/logs" \
    atlassianlabs/terraform:2.9.15 ./uninstall.sh -c conf.tfvars || {
      echo ">>> Graceful uninstall failed. Attempting force termination..."
      docker run --pull=always --env-file aws_envs \
        --workdir="//data-center-terraform" \
        --entrypoint="python" \
        -v "/$PWD/terminate_cluster.py:/data-center-terraform/terminate_cluster.py" \
        atlassian/dcapt terminate_cluster.py --cluster_name "atlas-${ENVIRONMENT_NAME}-cluster" --aws_region "$REGION"
    }

  cd "$TOOLKIT_ROOT" || exit 1
  echo ">>> Cluster terminated."
fi

echo "=================================================================="
echo "=== ALL TESTS COMPLETE! ==="
echo "1. Your screenshot is saved in the root folder as: lucene_reindex_screenshot.png"
echo "2. Your Atlassian submission reports are located in: app/results/reports/"
echo "=================================================================="

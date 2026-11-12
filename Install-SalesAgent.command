#!/bin/bash
# Sales Agent - double-click (macOS) or run (Linux) to install or update.
# Runs Install-SalesAgent.ps1 with PowerShell 7.
cd "$(dirname "$0")" || exit 1
if ! command -v pwsh >/dev/null 2>&1; then
  echo "PowerShell 7 is required to install Sales Agent."
  if [[ "$(uname)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    read -r -p "Install it now with Homebrew (brew install --cask powershell)? [y/N] " a
    [[ "$a" =~ ^[Yy] ]] && brew install --cask powershell
  fi
fi
if ! command -v pwsh >/dev/null 2>&1; then
  echo "Install PowerShell 7 from https://aka.ms/powershell and run this file again."
  read -r -p "Press Enter to close." _
  exit 1
fi
pwsh -NoLogo -NoProfile -File ./Install-SalesAgent.ps1 "$@"
rc=$?
echo
read -r -p "Press Enter to close." _
exit $rc

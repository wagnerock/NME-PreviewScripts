---
name: nme-write-scripted-actions
description: >
  Write, review, and improve PowerShell scripted actions for Nerdio Manager for Enterprise (NME).
  Use when the user wants to write, review, or modify a scripted action .ps1 file locally.
argument-hint: "write | review"
allowed-tools: Read Edit Write
---

# NME Write Scripted Actions Skill

Help users write, review, and improve PowerShell scripted actions for Nerdio Manager for
Enterprise.

## Writing Scripts

When the user asks to write, review, or modify a scripted action, consult the appropriate guide
based on execution environment. If the environment is not specified, ask.

- **Azure Runbook Scripted Actions** (`executionEnvironment: AzureAutomation`): scripts that call Azure
  APIs, manage AVD resources, or need Az PowerShell modules. Read [`references/writing-runbook-action.md`](references/writing-runbook-action.md).
- **Windows Scripted Actionss** (`executionEnvironment: CustomScript`): scripts that run directly on a
  session host to configure Windows, install software, or read local state. Read [`references/writing-windows-action.md`](references/writing-windows-action.md).

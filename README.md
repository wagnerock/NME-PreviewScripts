# NME Preview Scripts

Resources for developing and testing scripted actions in [Nerdio Manager for Enterprise (NME)](https://getnerdio.com/nerdio-manager-for-enterprise/).

## Repository Structure

```
scripted-actions/       PowerShell scripts for testing in NME
  azure-runbooks/         Azure Automation runbook scripts (executionEnvironment: AzureAutomation)
  windows-scripts/        Windows session host scripts (executionEnvironment: CustomScript)

skills/                 Claude / AI assistant skills for managing NME via the API
  nme-manage-scripted-actions/   CRUD and execute scripted actions via the NME REST API
  nme-write-scripted-actions/    Write and review NME scripted actions
```

## Scripted Actions

Scripts in `scripted-actions/` are PowerShell files intended for upload to and execution in a live NME instance. 

These are experimental scripted actions and not intended for production use.

You can link NME to this repository to import these runbooks.

**Azure Runbooks** (`azure-runbooks/`) run in NME's Azure Automation account. They have access to Az PowerShell modules and run as NME's service principal — not on a VM.

**Windows Scripts** (`windows-scripts/`) run directly on AVD session hosts via the Custom Script Extension.

## Skills

Skills in `skills/` are AI assistant integrations for use with Claude Code or other AI tools. Each skill has a `SKILL.md` that defines its behavior and a `scripts/` directory with supporting helpers.

### nme-manage-scripted-actions

Manage scripted actions in a live NME instance via the REST API. Invoke with `/nme-manage-scripted-actions` in Claude Code.

Supports: listing, creating, updating, deleting, and executing scripted actions; polling job output; listing host pool session hosts.

Requires environment variables:
```
NME_BASE_URL       https://<nme-instance>
NME_CLIENT_ID      OAuth2 app/client ID
NME_CLIENT_SECRET  OAuth2 client secret
NME_TENANT_ID      Entra tenant ID
NME_SCOPE          api://<nme-app-id>/.default
```

### nme-write-scripted-actions

Write, review, and improve NME scripted actions. Invoke with `/nme-write-scripted-actions` in Claude Code. Includes reference guides for both Azure Runbook and Windows script conventions.

## Installing Skills in Claude Code

See the official [Claude Code skills documentation](https://docs.anthropic.com/en/docs/claude-code/slash-commands) for full details.

Skills are installed by copying the skill directory into `~/.claude/skills/`:

```bash
cp -r skills/nme-manage-scripted-actions ~/.claude/skills/
cp -r skills/nme-write-scripted-actions ~/.claude/skills/
```

Once installed, invoke a skill by name in Claude Code:

```
/nme-manage-scripted-actions list
/nme-write-scripted-actions
```

Claude will also use skills automatically when the task matches their description.

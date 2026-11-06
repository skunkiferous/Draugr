# TODO: tidy the HOST VS Code

Personal housekeeping, **not part of Draugr**. Nothing here affects the forge, the gateway
or any VM — it is about the VS Code on this workstation.

Findings measured from `code --list-extensions`,
`%USERPROFILE%\.vscode\extensions` and `%APPDATA%\Code\User\settings.json`.
**64 extensions installed, 70 directories on disk.**

Useful commands:

```
code --list-extensions --show-versions
code --uninstall-extension <publisher.name>
```

Settings file: `C:\Users\<you>\AppData\Roaming\Code\User\settings.json`

---

## 1. Python paths point at a project that no longer exists

```json
"python.autoComplete.extraPaths": ["C:\\UE4\\UnrealProjects\\CPPTest\\Intermediate\\PythonStub"],
"python.analysis.extraPaths":     ["C:\\UE4\\UnrealProjects\\CPPTest\\Intermediate\\PythonStub"]
```

- [ ] `C:\UE4\UnrealProjects\CPPTest\` **does not exist**. What is there now:
      `AA_53_CPP`, `AS_53_CPP_LOC`, `DAW_Plugin`, `SurvivalGame`, `ThirdPartySounds`.
- [ ] None of those has an `Intermediate\PythonStub` either — the stub only appears once
      the Python plugin is enabled in the UE editor for that project.
- [ ] So this setting currently does nothing. Either delete it, or repoint
      `python.analysis.extraPaths` at a live project once its stub exists.
- [ ] Drop `python.autoComplete.extraPaths` regardless — that is the legacy Jedi setting,
      superseded by `python.analysis.extraPaths` under Pylance.

*(Worth keeping the habit: pointing Pylance at the stub is what gives completion for the
`unreal` module. It is the single most useful Python setting for UE work.)*

## 2. Two Lua language servers are fighting

- [ ] `sumneko.lua@3.19.1` **and** `tangzx.emmylua@0.9.41` are both installed.
- [ ] Both are full language servers, so Lua files get duplicate completions and
      duplicate diagnostics.
- [ ] `settings.json` already picks a side for formatting:
      `"[lua]": { "editor.defaultFormatter": "tangzx.emmylua" }` — so EmmyLua is probably
      the keeper, but decide deliberately and uninstall the other.
- [ ] `pdesaulniers.vscode-teal@0.11.0` is a separate thing (Teal = typed Lua), not a
      conflict. Keep if Teal is still in use.

## 3. Codeium is gone but its leftovers are not

- [ ] Not in `code --list-extensions`, yet `codeium.codeium-1.48.2` is still on disk.
- [ ] Five dead keys in `settings.json`: `codeium.enableConfig`, `codeium.snoozeTime`,
      `codeium.disableTabJump`, `codeium.detectProxy`,
      `codeium.languageServerStartupTimeout`.

## 4. Stale duplicate versions on disk

70 directories for 64 extensions. VS Code usually removes the old version and here it has
not:

- [ ] `anthropic.claude-code` — 2.1.288 **and** 2.1.289
- [ ] `openai.chatgpt` — 26.930.31730 **and** 26.930.41038
- [ ] `openai.codex-audio` — 26.930.31730 **and** 26.930.41038
- [ ] `ms-toolsai.jupyter` — 2025.6.0 **and** 2025.9.1

Safe to delete the older directory of each pair while VS Code is closed.

## 5. Five overlapping CSV/TSV tools

- [ ] `ctenbrinke.vscode-tsv`, `mechatroner.rainbow-csv`, `janisdd.vscode-edit-csv`,
      `grapecity.gc-excelviewer`, `ms-toolsai.datawrangler`.
- [ ] Only one of them is actually configured — `csv-edit.*` (that is `janisdd`), with
      header, quote and escape options set. The rest may be unused.
- [ ] Related: `"files.associations": { "*.mod": "csv" }` is a deliberate convention and
      worth keeping.

## 6. Six AI assistants installed at once

- [ ] `anthropic.claude-code`, `saoudrizwan.claude-dev` (Cline), `openai.chatgpt`,
      `openai.codex-audio`, `doublebot.doublebot`, `lastmile-ai.vscode-aiconfig`.
- [ ] `"chat.disableAIFeatures": true` is already set, so the built-in one is off.
- [ ] Decide which are genuinely in use; each one is a background process and a
      completion provider competing for the same keystrokes.

## 7. Language stacks — only if unused

Not a problem if these are live. Listed because they are a lot of weight if they are not:

- [ ] Java (5): `redhat.java`, `vscjava.vscode-java-pack`, `vscjava.vscode-gradle`,
      `vscjava.vscode-java-debug`, `vscjava.vscode-java-dependency`
- [ ] .NET/C# (3): `ms-dotnettools.csharp`, `ms-dotnettools.csdevkit`,
      `ms-dotnettools.vscode-dotnet-runtime`
      — **keep `csharp` if you ever edit UnrealBuildTool**, which is C#.
- [ ] `ms-vscode.cmake-tools` — UE builds with UnrealBuildTool, not CMake. Keep only if
      some other project needs it.

## 8. One security setting worth a conscious decision

- [ ] `"security.workspace.trust.untrustedFiles": "open"` opens files from untrusted
      folders without the trust prompt. Probably set once to stop a nag. Given how much
      care goes into sandboxing elsewhere, worth deciding on purpose rather than leaving
      it as a default that was clicked away.

---

## For reference: what went into the forge VMs

The VM core is deliberately tiny — four extensions:

| extension | for |
|---|---|
| `ms-vscode.cpptools` | C/C++ (the bare extension, **not** the pack — it drags in CMake Tools) |
| `ms-python.python` | Python; Pylance and debugpy come as dependencies |
| `tangzx.emmylua` | Lua (matching the host's formatter choice) |
| `mechatroner.rainbow-csv` | TSV colouring, alignment, RBQL |

Plus `janisdd.vscode-edit-csv` if the TSV *table editor* is wanted.

Deliberately excluded: `hazelight.unreal-angelscript` (per-project, not base), the C++
extension pack, GitHub Copilot (`**.githubcopilot.com` is denied by the kit), GitLens.

No JSON extension: VS Code's built-in `json-language-features` plus the `jq` already in
the guest covers it. `json.schemastore.org` is denied by the kit, so set
`"json.schemaDownload.enable": false` in the VM to stop it retrying and complaining.

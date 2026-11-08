# TODO: tidy the HOST VS Code

Personal housekeeping, **not part of Draugr**. Nothing here affects the forge, the gateway or any
VM. It is about the VS Code on this workstation.

Results measured from `code --list-extensions`, `%USERPROFILE%\.vscode\extensions` and
`%APPDATA%\Code\User\settings.json`. **64 extensions installed, 70 directories on disk.**

Useful commands:

```
code --list-extensions --show-versions
code --uninstall-extension <publisher.name>
```

Configuration file: `C:\Users\<you>\AppData\Roaming\Code\User\settings.json`

---

## 1. Python paths point at a project that no longer exists

```json
"python.autoComplete.extraPaths": ["C:\\UE4\\UnrealProjects\\CPPTest\\Intermediate\\PythonStub"],
"python.analysis.extraPaths":     ["C:\\UE4\\UnrealProjects\\CPPTest\\Intermediate\\PythonStub"]
```

- [ ] `C:\UE4\UnrealProjects\CPPTest\` **does not exist**. These exist now: `AA_53_CPP`,
      `AS_53_CPP_LOC`, `DAW_Plugin`, `SurvivalGame`, `ThirdPartySounds`.
- [ ] None of those has an `Intermediate\PythonStub` either. The stub shows only after you enable
      the Python plugin in the UE editor for that project.
- [ ] Thus this value now does nothing. Delete it, or point `python.analysis.extraPaths` at a live
      project after its stub exists.
- [ ] Remove `python.autoComplete.extraPaths` in all cases. That is the legacy Jedi value, which
      `python.analysis.extraPaths` replaces under Pylance.

*(Keep the habit. Pylance pointed at the stub gives completion for the `unreal` module. It is the
most useful Python value for UE work.)*

## 2. Two Lua language servers are fighting

- [ ] `sumneko.lua@3.19.1` **and** `tangzx.emmylua@0.9.41` are both installed.
- [ ] Both are full language servers. Thus Lua files get duplicate completions and duplicate
      diagnostics.
- [ ] `settings.json` already selects one for formatting:
      `"[lua]": { "editor.defaultFormatter": "tangzx.emmylua" }`. Thus EmmyLua is probably the one
      to keep. Decide on purpose, and uninstall the other.
- [ ] `pdesaulniers.vscode-teal@0.11.0` is a separate thing (Teal is typed Lua), not a conflict.
      Keep it if you still use Teal.

## 3. Codeium is gone but its leftovers are not

- [ ] Not in `code --list-extensions`, but `codeium.codeium-1.48.2` is still on disk.
- [ ] Five dead keys in `settings.json`: `codeium.enableConfig`, `codeium.snoozeTime`,
      `codeium.disableTabJump`, `codeium.detectProxy`, `codeium.languageServerStartupTimeout`.

## 4. Stale duplicate versions on disk

70 directories for 64 extensions. VS Code usually removes the old version, but here it did not:

- [ ] `anthropic.claude-code`: 2.1.288 **and** 2.1.289
- [ ] `openai.chatgpt`: 26.930.31730 **and** 26.930.41038
- [ ] `openai.codex-audio`: 26.930.31730 **and** 26.930.41038
- [ ] `ms-toolsai.jupyter`: 2025.6.0 **and** 2025.9.1

While VS Code is closed, you can safely delete the older directory of each pair.

## 5. Five overlapping CSV/TSV tools

- [ ] `ctenbrinke.vscode-tsv`, `mechatroner.rainbow-csv`, `janisdd.vscode-edit-csv`,
      `grapecity.gc-excelviewer`, `ms-toolsai.datawrangler`.
- [ ] Only one of them has values set: `csv-edit.*` (that is `janisdd`), with header, quote and
      escape options. The others are possibly unused.
- [ ] Related: `"files.associations": { "*.mod": "csv" }` is a convention on purpose. Keep it.

## 6. Six AI assistants installed at once

- [ ] `anthropic.claude-code`, `saoudrizwan.claude-dev` (Cline), `openai.chatgpt`,
      `openai.codex-audio`, `doublebot.doublebot`, `lastmile-ai.vscode-aiconfig`.
- [ ] `"chat.disableAIFeatures": true` is already set, so the built-in one is off.
- [ ] Decide which ones you really use. Each one is a background process and a completion provider
      that competes for the same keystrokes.

## 7. Language stacks — only if unused

If you use these, there is no problem. They are listed because they are heavy if you do not:

- [ ] Java (5): `redhat.java`, `vscjava.vscode-java-pack`, `vscjava.vscode-gradle`,
      `vscjava.vscode-java-debug`, `vscjava.vscode-java-dependency`
- [ ] .NET/C# (3): `ms-dotnettools.csharp`, `ms-dotnettools.csdevkit`,
      `ms-dotnettools.vscode-dotnet-runtime`. **Keep `csharp` if you ever edit UnrealBuildTool**,
      which is C#.
- [ ] `ms-vscode.cmake-tools`: UE builds with UnrealBuildTool, not CMake. Keep it only if a
      different project needs it.

## 8. One security setting worth a conscious decision

- [ ] `"security.workspace.trust.untrustedFiles": "open"` opens files from untrusted folders with no
      trust prompt. Probably somebody set it once to stop a prompt. With all the care for sandboxes
      in other places, decide this on purpose. Do not keep it only because somebody clicked a prompt
      away.

---

## For reference: what went into the forge VMs

The VM core is very small, on purpose: four extensions.

| extension | for |
|---|---|
| `ms-vscode.cpptools` | C/C++ (the bare extension, **not** the pack, which brings in CMake Tools) |
| `ms-python.python` | Python. Pylance and debugpy come as dependencies |
| `tangzx.emmylua` | Lua (matching the formatter choice of the host) |
| `mechatroner.rainbow-csv` | TSV colors, alignment, RBQL |

Add `janisdd.vscode-edit-csv` if you want the TSV *table editor*.

Left out on purpose: `hazelight.unreal-angelscript` (for each project, not the base), the C++
extension pack, GitHub Copilot (the kit denies `**.githubcopilot.com`), GitLens.

No JSON extension. The built-in `json-language-features` of VS Code and the `jq` that is already in
the guest cover it. The kit denies `json.schemastore.org`. Thus set
`"json.schemaDownload.enable": false` in the VM, so that it stops its retries and errors.

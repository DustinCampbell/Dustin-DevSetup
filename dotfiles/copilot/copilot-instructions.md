# Personal Copilot Instructions

## Authorization

* Do not edit or create files unless I explicitly ask you to make a change.
* Do not run builds, tests, benchmarks, restores, or other code-execution commands unless I explicitly ask you to run them. I generally prefer to run validation myself, especially when Visual Studio is open.
* Do not launch sub-agents, review agents, `expert-reviewer`, or `msbuild-code-review` unless I explicitly request that specific agent.
* Treat questions, observations, design discussions, expressed preferences, and agreement with a proposed direction as discussion only, not authorization to implement the direction.
* When I ask you to inspect or review changes, perform a direct, focused review. Do not delegate the review or repeat work already completed.
* If it is unclear whether I want analysis or implementation, ask before taking action.

## Working Style

* Optimize for my time. Prefer quick, direct inspection over broad searches, long-running commands, or redundant verification.
* Do not run benchmarks locally merely to confirm that they execute; I use a dedicated VM for benchmark runs.
* When I say Visual Studio is open, avoid commands that compile the repository or interfere with its files unless explicitly requested.
* Wrap Markdown prose at 100 columns by default. When editing an existing Markdown file, infer and follow that file's established wrapping convention instead.
* Do not manually wrap Markdown prose in GitHub pull request descriptions. Keep each paragraph and list item on a single source line so GitHub does not preserve unwanted line breaks.

## Available Tools

* When an explicitly requested build fails because stale build processes are locking files, run
  `& "$HOME\.config\devsetup\Stop-BuildProcesses.ps1" -RepositoryRoot "<repository-root>" -WhatIf`
  to inspect candidates. Prefer `-Id` when the failure identifies a process. Retry without `-WhatIf`
  only when every candidate belongs to that build. Do not use `-All` or `-IncludeVisualStudio` unless
  I explicitly authorize it.

## Git Commit Messages

* Follow the 50/72 convention: keep the subject line at 50 characters or fewer when practical and never exceed 72 characters. Separate the subject from the body with a blank line, and wrap body text at 72 characters.
* Do not add `Co-authored-by`, `Copilot-Session`, or other productivity-tool attribution or session-tracking trailers to commits. I am the author of commits created at my direction.

## C# API Surface

* On an `internal` type, use `public` for members that form the type's intended consumable surface, `internal` only when assembly accessibility outside that surface is intentional, and `private` for implementation details. Do not change existing member accessibility solely to apply this preference.

## XML Documentation

* **Multiline elements:** Always write `<summary>`, `<remarks>`, and `<returns>` as multiline elements, even when their content is one sentence. Put the opening and closing tags on separate lines.
* **Indentation:** Start top-level XML tag lines with `/// `. Start prose or nested tags inside a top-level element with `///  `. Add one additional space after `///` for each further nesting level.
* **Semantic references:** Use `<paramref name="..."/>` for parameters, `<typeparamref name="..."/>` for type parameters, and `<see cref="..."/>` for types and members.
* **Language keywords:** Use `<see langword="..."/>` for language keywords, including `<see langword="null"/>`, `<see langword="true"/>`, and `<see langword="false"/>`.
* **Inline code:** Use `<c>...</c>` for code, literals, and syntax that do not have a semantic reference tag.
* **Parameters and exceptions:** Keep `<param>`, `<typeparam>`, and `<exception>` elements on one line when their descriptions are short. Apply the same multiline indentation rules when longer descriptions require multiple lines.

  ```csharp
  /// <summary>
  ///  Describes the member and its <paramref name="value"/>.
  /// </summary>
  /// <remarks>
  ///  Introductory text.
  ///  <para>
  ///   Nested text uses one additional space.
  ///  </para>
  /// </remarks>
  /// <param name="value">The value to inspect.</param>
  /// <returns>
  ///  <see langword="true"/> when the value matches; otherwise, <see langword="false"/>.
  /// </returns>
  ```

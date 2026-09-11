# Contributing to SoundWave

Thank you for your interest in contributing to SoundWave!

SoundWave is an open-source project, and every contribution can help make it better. Whether you're fixing a bug, improving the UI, adding a feature, improving documentation, or simply sharing an idea, you're welcome here.

You don't have to be an expert to contribute. If you're new to open source, feel free to ask questions and start small.

## Before You Start

Before making a contribution, please take a moment to:

* Read the [Code of Conduct](CODE_OF_CONDUCT.md).
* Check existing issues and pull requests to see if your idea or problem has already been discussed.
* For larger changes, consider opening an issue first so we can discuss the approach before you spend time implementing it.

## How to Contribute

### 1. Fork the Repository

Create your own fork of the SoundWave repository and clone it to your local machine.

```bash
git clone https://github.com/tejasshinde4545k/SoundWave.git
cd SoundWave
```

### 2. Create a Branch

Create a separate branch for your changes instead of working directly on the main branch.

```bash
git checkout -b feature/my-new-feature
```

Choose a branch name that briefly describes what you're working on. For example:

```text
feature/queue-improvements
fix/player-crash
ui/now-playing-screen
docs/setup-guide
```

### 3. Make Your Changes

Make your changes while keeping the existing project structure and coding style in mind.

Try to keep each pull request focused on one feature, improvement, or bug fix. Smaller and focused changes are generally easier to review.

### 4. Test Your Changes

Before opening a pull request, make sure your changes work as expected.

For Flutter changes, run:

```bash
flutter analyze
flutter test
```

If your changes affect the user interface or playback behavior, test them on a real device or emulator whenever possible.

Please make sure your changes don't introduce new warnings, errors, or broken functionality.

### 5. Commit Your Changes

Write a clear commit message that explains what you changed.

For example:

```text
Add recently played section to dashboard
```

or:

```text
Fix playback state when changing tracks
```

Try to avoid vague messages such as:

```text
fixed stuff
changes
update
```

### 6. Push Your Branch

Push your branch to your fork:

```bash
git push origin feature/my-new-feature
```

### 7. Open a Pull Request

Open a pull request against the main SoundWave repository.

In your pull request, please explain:

* What you changed.
* Why you made the change.
* How you tested it.
* Any important details reviewers should know.
* Screenshots or recordings if the change affects the UI.

A clear description makes it much easier for everyone to understand and review your contribution.

## Reporting Bugs

Found something that doesn't work correctly?

Please check the existing issues first. If the problem hasn't already been reported, open a new issue and include as much useful information as possible.

Helpful details include:

* What happened.
* What you expected to happen.
* Steps to reproduce the problem.
* Device and Android version.
* SoundWave version or commit.
* Relevant error messages or logs.
* Screenshots or screen recordings when helpful.

A good bug report helps us reproduce and fix the problem faster.

## Suggesting Features

Have an idea that could make SoundWave better?

We'd love to hear it.

Before opening a feature request, check whether a similar idea has already been suggested. When creating a new request, explain:

* What you'd like to see.
* Why you think it would be useful.
* How you imagine it working.
* Any examples or references that might help.

Not every suggestion will necessarily be implemented, but thoughtful ideas and discussions are always welcome.

## Pull Request Guidelines

Before submitting a pull request, please make sure that:

* Your changes are focused and easy to understand.
* Existing functionality continues to work.
* Code follows the project's existing style and structure.
* Tests have been added or updated when appropriate.
* `flutter analyze` passes without new issues.
* You have tested the changes locally.
* UI changes include screenshots or recordings when useful.
* The pull request description clearly explains the changes.

Please don't take review comments personally. Code review is part of working together, and suggestions are intended to improve the project.

You may be asked to make changes before your pull request is merged. That's completely normal.

## Code Reviews

Pull requests will be reviewed by the project maintainers.

Reviews may take some time depending on the size and complexity of the change. Please be patient, and feel free to respond to review comments or ask questions if something isn't clear.

We aim to keep reviews constructive, respectful, and focused on making SoundWave better.

## Documentation Contributions

Contributions don't always have to involve code.

You can also help by:

* Fixing spelling or grammar.
* Improving documentation.
* Adding setup instructions.
* Improving examples.
* Clarifying confusing explanations.
* Sharing troubleshooting steps.

These contributions are valuable and can make the project much easier for others to use.

## Attribution

By submitting a contribution to SoundWave, you agree that your contribution may be used, modified, and distributed as part of the project under its applicable license.

Please make sure that any code, assets, or other material you contribute is something you have the right to share.

## Questions and Discussions

If you're unsure about something, don't hesitate to ask.

Open-source projects work best when people communicate, share ideas, and help each other. A question that seems simple to you may also be something another contributor is wondering about.

We're happy to have you here.

## Thank You

Whether you submit your first bug report, improve a sentence in the documentation, suggest a feature, or contribute a major change, **thank you for helping make SoundWave better.**

Every contribution matters.

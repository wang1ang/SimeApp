# Repository Guidelines

## Project Structure & Module Organization
`Android/` contains the Gradle APK project, Java IME code, JNI bridge, resources,
and JUnit tests. `macOS/` contains the InputMethodKit frontend, Swift UI, C API
adapter, and package scripts. `Linux/fcitx5/` contains the Fcitx5 plugin, while
`Linux/package/` contains Arch packaging files. Shared CMake dependency logic is
under `cmake/`. The C++ engine lives in the sibling `Sime` repository.

## Engine Dependency
Keep `SimeApp` and `Sime` as sibling directories for local development. For a
different layout, set `SIME_ENGINE_ROOT` or pass
`-DSIME_ENGINE_ROOT=/path/to/Sime`. Platform adapters belong here; reusable
decoder and language-model code belongs in Sime.

## Build, Test, and Development Commands
Run Android checks from `Android/`:
```bash
./gradlew testDebugUnitTest
./gradlew assembleDebug
```
Build Fcitx5 from the repository root:
```bash
cmake -S Linux/fcitx5 -B build/fcitx5 -DCMAKE_BUILD_TYPE=Release
cmake --build build/fcitx5
```
On macOS, configure `macOS/` with the Xcode generator. Generated `sime.dict`
and `sime.cnt` come from the engine repository and are not committed here.

## Coding Style & Naming Conventions
Use 4-space indentation. Java types use `PascalCase` and methods/fields use
`camelCase`; tests end in `Test.java`. C++ follows the engine's warning-clean
C++20 style. Swift types use `PascalCase` and members use `camelCase`. Avoid
unrelated formatting changes.

## Testing Guidelines
Add focused JUnit 4 tests under `Android/app/src/test/` for input state,
candidate selection, and layout switching. Verify native integration with an
APK build. Exercise macOS and Fcitx5 changes on their target platform and list
the exact build commands in the PR.

## iOS Regression Contract
Before implementing or evaluating any new iOS request, read
`iOS/REGRESSION.md` and check the request against every relevant recorded
behavior contract. If the new request conflicts with that document, explicitly
notify the user before implementation, explain the conflicting entries, and
confirm the intended behavior. After the conflict is resolved, update
`iOS/REGRESSION.md` in the same change so it remains accurate. Before adding an
entry, search the automated tests: if a behavior is already covered, the test
is its source of truth and the contract document must not duplicate it.
`iOS/REGRESSION.md` records only requirements and manual/device regressions
that automated tests do not cover. New regressions should preferably become
tests; add them to the document only while they still require manual coverage.
Do not let code, tests, and the document silently diverge.

## Commit & Pull Request Guidelines
Use short, imperative, platform-scoped subjects such as `Android: fix T9
selection`. PRs should describe the affected frontend, required Sime engine
revision, verification commands, and any model/resource assumptions. Include
screenshots or recordings for visible keyboard and candidate-window changes.
Never commit SDK paths, signing keys, generated packages, model binaries, or
user data.

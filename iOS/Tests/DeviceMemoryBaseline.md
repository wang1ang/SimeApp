# Keyboard memory and Jetsam baseline

Run this test on a physical device. Simulator unit tests do not reproduce the
keyboard extension's per-process memory limit.

## Preparation

1. Make a Release build and install it on the device.
2. Record the build number shown on the space bar.
3. Start a device log capture and save it as `/tmp/sime-device.log`.
4. Open a fresh note and select SimeKeyboard with Microsoft Shuangpin enabled.

Do not run Instruments during the Jetsam survival pass: its attachment changes
process lifetime and memory behavior. Use a separate run when collecting a
footprint trace.

## Fixed workload

Perform the following without switching to another keyboard:

1. Type `xcg`, delete `g`, then type `go`; repeat 10 times.
2. Type `womfdevsgo` (我们的中国), commit with Space, and repeat 20 times.
3. Type `x;jwbi` (性价比), select the middle character, choose a correction,
   append another syllable, and commit; repeat 10 times.
4. Select 20 consecutive next-word predictions.
5. Move between two text fields 20 times, leaving an unfinished odd-key
   composition before each move.
6. Delete a composition to empty, then exercise Space and Return once each.

## Required observations

For the survival run, record:

- device model and iOS version;
- Release build number shown on the space bar;
- whether the keyboard remained visible after every first decode and correction;
- whether unfinished composition leaked into the other text field;
- the captured device log.

Check the log with:

```bash
iOS/scripts/check-keyboard-jetsam-log.sh /tmp/sime-device.log
```

Any `SimeKeyboard` `per-process-limit`, `exceeded mem limit`, or Jetsam event is
a failure, even if iOS immediately reloads the keyboard.

For a separate Instruments run, record the extension footprint at these points:

1. keyboard first shown;
2. Native decoder initialized;
3. first complete sentence decoded;
4. first correction list opened;
5. end of the fixed workload;
6. peak footprint during the run.

The known device ceiling is 77 MB. Record measurements before changing Native
loading or decoding so later stages can compare against the same workload.

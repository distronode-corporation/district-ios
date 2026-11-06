# Live supervise screenshots (PR #101)

Not code. Frames for the iOS and Apple Watch live supervise PR, taken with
`xcrun simctl io screenshot`, made-up data only.

- iPhone 17 Pro simulator, `{en,fr}-{light,dark}-NN-<state>.png`: 18 states in each of
  English light, English dark, French light and French dark. The app ran against a loopback
  fixture server with the debug-only staged device (no real call, no media), driven by
  `LiveSuperviseScreenshotTests`.
- Apple Watch Series 11 (46 mm) simulator, `watch-{en,fr-CA}-receipt-{used,notUsed}.png`: the
  whisper receipt on the live call screen, from the watch's debug preview.

States: 01 empty list, 02 list, 03 idle, 04 connecting, 05 listening, 06 receipt used,
07 take-over confirmation, 08 taking over, 09 taken over, 10 taken over and muted,
11 handed back with a receipt not used, 12 call ended, 13 list after the call ended,
14 a colleague's own call (listen only), 15 listening to it, 16 listen refused (call ended),
17 viewer, 18 viewer listening.

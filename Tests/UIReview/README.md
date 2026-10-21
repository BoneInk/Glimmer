# Native isolated UI review

Build from the project root:

```sh
scripts/build-ui-review.sh
open -n evidence/ui-review-build/GlimmerReview.app
```

The separate app uses bundle identifier `com.boneinkzhong.glimmer.review` and a window title containing `界面验证`. It opens real public Workshop discovery. Its Steam account is empty and its SteamCMD layout, browser preferences, library, thumbnails, preview cache, settings, policy and playlist are under a fresh system temporary directory. The executable prints that directory at launch. Temporary files are retained for inspection after quitting.

The review build compiles production sources except `AppMain.swift`, with `Tests/UIReview/UIReviewMain.swift` as its separate entry point. `GW_UI_REVIEW` makes every default `AppStorage` use the review root, including shared caches. The production app is compiled without that flag. The production AppDelegate is never instantiated by the harness, and no saved desktop assignments are restored. Both Apply and desktop-preview actions use a controller with `previewOnly: true, writesToLibrary: false`, so they create no desktop overlays.

A copy of `evidence/ui-test-video.mp4` is bundled for local preview and library inspection. It is labeled `界面验证视频（演示素材）` and is not evidence of a Steam download. To instead inspect an already-downloaded public video, pass its exact media path:

```sh
open -n evidence/ui-review-build/GlimmerReview.app --args \
  --media '/path/to/public/video.mp4' \
  --workshop-id 1234567890 --media-title 'Public work title'
```

Only this selected video is copied. The harness generates its own minimal video `project.json` and validates it through the production resolver. It never copies Steam home, configuration, credentials, logs, or downloaded manifests. Account/dependency pages remain available with the isolated, initially empty account.

Add `--library` to start in the local library instead of Workshop discovery. The login-item service is intentionally unsupported in the review app. The build script builds and signs the review bundle only; launching remains explicit so it cannot disturb the production UI during compilation.

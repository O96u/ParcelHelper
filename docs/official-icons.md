# Publisher-provided app artwork (not synthetic icons)

The icons fetched by GitHub Actions are the **original artworks uploaded by
listed publishers to Apple App Store**. These are app icons, *not necessarily
the company's corporate trademark/VI logo*. The downloader performs title
and publisher string checks and skips missing or ambiguous matches.
It does not trace, redraw, upscale or generate imitation marks.

* Source manifest: docs/official-icon-source-manifest.json (created by workflow)
* Downloader: tools/download_official_icons.py
* Workflow: .github/workflows/official-icons.yml
* Missing assets are intentionally left unchanged; the existing courier atlas
  may therefore remain blurry for brands whose official apps cannot be verified.
* All marks are owned by their respective rights holders; review the rights
  before redistributing a released application. Apple's Store API also has
  usage terms. This repository does not receive trademark licenses from Apple.
* iOS may suspend the app while a Live Activity is shown. The 5/10/30/120-minute
  timeout is best effort, not a guarantee of exact background dismissal.

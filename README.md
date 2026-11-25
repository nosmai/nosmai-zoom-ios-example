# Nosmai Effects with Zoom Video SDK on iOS

The host sends processed camera frames through Zoom’s external video source. The viewer subscribes to the host’s video canvas.

## Requirements

- Xcode, CocoaPods and two physical iOS devices running iOS 15 or later.
- A Nosmai Effects licence for the broadcaster’s bundle identifier. The Xcode project uses `com.nosmai.quickstart.zoom`.
- The Podfile pins `NosmaiCameraSDK 3.0.7` and `ZoomVideoSDK 2.6.15`.

## Set up the project

From the repository root, create the local configuration and install the dependencies.

```sh
cp Configuration/Example.plist Configuration/Local.plist
pod install
open NosmaiZoomDemo.xcworkspace
```

In Xcode, select your signing team for the app target. If you change the bundle identifier, use the same identifier when registering the Nosmai licence. Set these fields in `Configuration/Local.plist`, which Git ignores.

- `nosmaiAPIKey` — App-bound Nosmai Effects licence for the broadcasting device. A viewer can leave this field empty.
- `sessionName` — The Zoom session name shared by both devices.

Issue a short-lived Zoom Video SDK session JWT on your server for each participant. Use the same session name as the app, with host role for the broadcaster and participant role for the viewer. Each phone prompts for its own token when joining.

## Broadcast and watch

1. On the first phone, select **Go Live (Host)** and allow camera and microphone access.
2. On the second phone, select **Watch (Audience)** and join the same session.
3. Open the host’s effects controls and apply a visible effect. Check the result on the viewer.
4. Leave the broadcast from the live screen to release the camera and session resources.

## Add Nosmai to an existing app

Use your existing Zoom session configuration. Set its `externalVideoSourceDelegate` to `NosmaiZoomVideoSource` on the broadcaster. The source receives Nosmai pixel buffers, converts them to I420 and supplies the rotation and dimensions requested by Zoom. The viewer uses the normal Zoom video canvas. Pair session exit with source shutdown to release the frame callback.

- [LiveViewController.swift](NosmaiZoomDemo/LiveViewController.swift) shows capture, publication, remote playback and teardown.
- [EffectsPanelView.swift](NosmaiZoomDemo/EffectsPanelView.swift) applies beauty controls, Cloud Filters and AR effects on the broadcaster.
- [NosmaiZoomVideoSource.swift](NosmaiZoomDemo/NosmaiZoomVideoSource.swift) adapts the Nosmai frame callback to the Zoom external video source.

## References

- [Nosmai iOS quickstart](https://nosmai.com/docs/effects/quickstart/ios/)
- [Register a Nosmai licence](https://nosmai.com/docs/effects/license-key/)
- [Zoom Video SDK authentication](https://developers.zoom.us/docs/video-sdk/auth/)

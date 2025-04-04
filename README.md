# `frame-ble`

Low level BLE communication for the [Brilliant Labs Frame](https://brilliant.xyz/) using [Flutter Blue Plus](https://pub.dev/packages/flutter_blue_plus).

[Frame SDK documentation](https://docs.brilliant.xyz/frame/frame-sdk/).

## Features

* Finds and connects to Frame
* sends Lua command strings to Frame
* sends data to frameside data receive handler for processing
* uploads Lua files to run on Frame
* subscribes to data streams from Frame

## See Also

* [`frame_msg`](https://pub.dev/packages/frame_msg): Application-level library for passing rich objects between a host program and Frame, such as images, streamed audio, IMU data and rasterized text.
* [`simple_frame_app`](https://pub.dev/packages/simple_frame_app) and its many example applications in [GitHub](https://github.com/CitizenOneX?tab=repositories) for demonstrations of [`frame_msg`](https://pub.dev/packages/frame_msg) being used by that framework.

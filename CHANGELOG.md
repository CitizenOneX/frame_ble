## 2.0.0

* Breaking: Added reconnect logic. Applications that need to connect to Frame when it becomes visible (e.g. wake on tap) need reconnect logic - the Noa app is an example. `BrilliantDevice.connectionState` changed its signature from `Stream<BrilliantConnectionState>` to `Stream<BrilliantDevice>` as part of this change.
* Logging of available memory on Frame during script uploads was removed

## 1.0.2

* Docs: updated package README

## 1.0.1

* added an await for adapterState to be on before attempting a scan, on iOS bluetooth startup can be a bit slower

## 1.0.0

* modified BrilliantDevice.connectionState to return only the state, not a new BrilliantDevice

## 0.0.1

* Initial release split from `simple_frame_app 4.0.2`

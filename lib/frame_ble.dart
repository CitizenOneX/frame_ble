/// Low level Bluetooth LE library helpers for Brilliant Labs Frame.
///
/// Provides Frame-specific command encoding, data parsing, and protocol handling
/// assuming the application manages the BLE connection using flutter_blue_plus.
library frame_ble;

// Export the BLE and DFU implementations for the Frame.
export 'frame_ble_impl.dart';
export 'frame_dfu_impl.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:logging/logging.dart';

final _log = Logger("FrameDfu");

// --- FrameDfu Class ---
class FrameDfu {
  static final Guid serviceUuid = Guid('fe59');
  static final Guid dfuControlCharUuid = Guid('8ec90001-f315-4f60-9fb8-838830daea50');
  static final Guid dfuPacketCharUuid = Guid('8ec90002-f315-4f60-9fb8-838830daea50');

  final BluetoothDevice device;
  late final BluetoothCharacteristic dfuControl;
  late final BluetoothCharacteristic dfuPacket;

  // Private constructor pattern to force async initialization
  FrameDfu._(this.device, this.dfuControl, this.dfuPacket);

  /// Creates and initializes a [FrameDfu] from the given [BluetoothDevice].
  ///
  /// Assumes the device is connected but services have not been discovered yet.
  /// This method handles MTU negotiation, service discovery, and characteristic setup.
  /// Throws an error if Frame services/characteristics are not found or notifications cannot be enabled.
  static Future<FrameDfu> fromDevice(BluetoothDevice device) async {
    _log.fine("Initializing FrameDfu for ${device.remoteId}...");

    // 1. Request MTU
    if (Platform.isAndroid) {
      try {
        await device.requestMtu(512);
         _log.fine("MTU requested");
      } catch (e) {
         _log.warning("MTU request failed: $e");
      }
    }

    // 2. Find Characteristics
    BluetoothCharacteristic? dfuControlChar;
    BluetoothCharacteristic? dfuPacketChar;

    // Note: We must call discoverServices after every re-connection
    List<BluetoothService> services = await device.discoverServices();

    for (var service in services) {
      if (service.serviceUuid == serviceUuid) {
        _log.fine("Found DFU service");
        for (var characteristic in service.characteristics) {
          if (characteristic.characteristicUuid == dfuControlCharUuid) {
            _log.fine("Found DFU Control characteristic");
            dfuControlChar = characteristic;
          } else if (characteristic.characteristicUuid == dfuPacketCharUuid) {
            _log.fine("Found DFU packet characteristic");
            dfuPacketChar = characteristic;
          }
        }
        break; // Found DFU service, no need to check others
      }
    }

    if (dfuControlChar == null || dfuPacketChar == null) {
       _log.severe("DFU Control and/or Packet characteristic not found!");
      throw Exception("DFU Control and/or Packet characteristic not found on device ${device.remoteId}");
    }

    // 3. Enable Control Characteristic Notifications
    try {
      if (!dfuControlChar.isNotifying) {
            await dfuControlChar.setNotifyValue(true);
            _log.fine("Enabled DFU Control characteristic notifications");
      } else {
            _log.fine("DFU Control characteristic notifications already enabled");
      }
    } catch (e) {
       _log.severe("Failed to enable DFU Control characteristic notifications: $e");
       throw Exception("Could not enable notifications on DFU Control characteristic: $e");
    }

    // 4. Calculate Max Lengths
    // Use device.mtuNow after MTU negotiation and connection
    int mtu = device.mtuNow;
    int maxStringLen = mtu - 3;
    int maxDataLen = mtu - 4;
    _log.fine("MTU: $mtu, Max String Length: $maxStringLen, Max Data Length: $maxDataLen");

    // 5. Delay to ensure the device is ready
    await Future.delayed(const Duration(milliseconds: 100));

    // 6. Create and return the instance
    return FrameDfu._(device, dfuControlChar, dfuPacketChar);
  }

  /// Checks if the given [ScanResult] is a Frame Update device.
  /// This is done by checking if the device's advertisement data contains the Frame service UUID.
  static bool isFrame(ScanResult result) {
    return result.advertisementData.serviceUuids.contains(serviceUuid) && result.advertisementData.advName == "Frame Update";
  }

  Stream<double> updateFirmware(String filePath) async* {
    try {
      yield 0;

      _log.info("Starting firmware update");

      final updateZipFile = await rootBundle.load(filePath);
      final zip = ZipDecoder().decodeBytes(updateZipFile.buffer.asUint8List());

      final initFile = zip.firstWhere((file) => file.name.endsWith(".dat"));
      final imageFile = zip.firstWhere((file) => file.name.endsWith(".bin"));

      await for (var _ in _transferDfuFile(initFile.content, true)) {}
      await Future.delayed(const Duration(milliseconds: 500));
      await for (var value in _transferDfuFile(imageFile.content, false)) {
        yield value;
      }

      _log.info("Firmware update completed");
    } catch (error) {
      _log.warning("Couldn't complete firmware update. $error");
      yield* Stream.error(Exception(error.toString()));
    }
  }

  Stream<double> _transferDfuFile(Uint8List file, bool isInitFile) async* {
    Uint8List response;

    try {
      if (isInitFile) {
        _log.fine("Uploading DFU init file. Size: ${file.length}");
        response = await _dfuSendControlData(Uint8List.fromList([0x06, 0x01]));
      } else {
        _log.fine("Uploading DFU image file. Size: ${file.length}");
        response = await _dfuSendControlData(Uint8List.fromList([0x06, 0x02]));
      }
    } catch (_) {
      throw ("Couldn't create DFU file on device");
    }

    final maxSize = ByteData.view(response.buffer).getUint32(3, Endian.little);
    var offset = ByteData.view(response.buffer).getUint32(7, Endian.little);
    final crc = ByteData.view(response.buffer).getUint32(11, Endian.little);

    _log.fine("Received allowed size: $maxSize, offset: $offset, CRC: $crc");

    while (offset < file.length) {
      final chunkSize = min(maxSize, file.length - offset);
      final chunkCrc = getCrc32(file.sublist(0, offset + chunkSize));

      // Create command with size
      final chunkSizeAsBytes = [
        chunkSize & 0xFF,
        chunkSize >> 8 & 0xFF,
        chunkSize >> 16 & 0xff,
        chunkSize >> 24 & 0xff
      ];

      try {
        if (isInitFile) {
          await _dfuSendControlData(
              Uint8List.fromList([0x01, 0x01, ...chunkSizeAsBytes]));
        } else {
          await _dfuSendControlData(
              Uint8List.fromList([0x01, 0x02, ...chunkSizeAsBytes]));
        }
      } catch (_) {
        throw ("Couldn't issue DFU create command");
      }

      // Split chunk into packets of MTU size
      final packetSize = device.mtuNow - 3;
      final packets = (chunkSize / packetSize).ceil();

      for (var p = 0; p < packets; p++) {
        final fileStart = offset + p * packetSize;
        var fileEnd = fileStart + packetSize;

        // The last packet could be smaller
        if (fileEnd - offset > maxSize) {
          fileEnd -= fileEnd - offset - maxSize;
        }

        // The last part of the file could also be smaller
        if (fileEnd > file.length) {
          fileEnd = file.length;
        }

        final fileSlice = file.sublist(fileStart, fileEnd);

        final percentDone = (100 / file.length) * offset;
        yield percentDone;

        _log.fine(
            "Sending ${fileSlice.length} bytes of packet data. ${percentDone.toInt()}% Complete");

        await _dfuSendPacketData(fileSlice)
            .onError((_, __) => throw ("Couldn't send DFU data"));
      }

      // Calculate CRC
      try {
        response = await _dfuSendControlData(Uint8List.fromList([0x03]));
      } catch (_) {
        throw ("Couldn't get CRC from device");
      }
      offset = ByteData.view(response.buffer).getUint32(3, Endian.little);
      final returnedCrc =
          ByteData.view(response.buffer).getUint32(7, Endian.little);

      if (returnedCrc != chunkCrc) {
        throw ("CRC mismatch after sending this chunk");
      }

      // Execute command (The last command may disconnect which is normal)
      try {
        response = await _dfuSendControlData(Uint8List.fromList([0x04]));
      } catch (_) {}
    }

    _log.fine("DFU file sent");
  }

  Future<Uint8List> _dfuSendControlData(Uint8List data) async {
    try {
      _log.fine("Sending ${data.length} bytes of DFU control data: $data");

      dfuControl.write(data, timeout: 1);

      final response = await dfuControl.onValueReceived
          .timeout(const Duration(seconds: 1))
          .first;

      return Uint8List.fromList(response);
    } catch (error) {
      return Future.error(Exception(error.toString()));
    }
  }

  Future<void> _dfuSendPacketData(Uint8List data) async {
    await dfuPacket.write(data, withoutResponse: true);
  }
}

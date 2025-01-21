
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:logging/logging.dart';

import 'brilliant_bluetooth_exception.dart';
import 'brilliant_connection_state.dart';

final _log = Logger("Bluetooth");

class BrilliantDevice {

  BluetoothDevice device;
  BrilliantConnectionState state;
  int? maxStringLength;
  int? maxDataLength;

  BluetoothCharacteristic? txChannel;
  BluetoothCharacteristic? rxChannel;

  BrilliantDevice({
    required this.state,
    required this.device,
    this.maxStringLength,
    this.maxDataLength,
  });

  // to enable reconnect()
  String get uuid => device.remoteId.str;

  Stream<BrilliantConnectionState> get connectionState {
    // changed to only listen for connectionState data coming from the Frame device rather than all events from all devices as before
    return device.connectionState
        .where((event) =>
            event == BluetoothConnectionState.connected ||
            (event == BluetoothConnectionState.disconnected &&
                device.disconnectReason != null &&
                device.disconnectReason!.code != 23789258))
        .asyncMap((event) async {
      if (event == BluetoothConnectionState.connected) {
        _log.info("Connection state stream: Connected");
        return BrilliantConnectionState.connected;
      }
      else {
        _log.info("Connection state stream: Disconnected");
        return BrilliantConnectionState.disconnected;
      }
    });
  }

  // logs each string message (messages without the 0x01 first byte) and provides a stream of the utf8-decoded strings
  // Lua error strings come through here too, so logging at info
  Stream<String> get stringResponse {
    // changed to only listen for data coming through the Frame's rx characteristic, not all attached devices as before
    return rxChannel!.onValueReceived
        .where((event) => event[0] != 0x01)
        .map((event) {
      if (event[0] != 0x02) {
        _log.info(() => "Received string: ${utf8.decode(event)}");
      }
      return utf8.decode(event);
    });
  }

  Stream<List<int>> get dataResponse {
    // changed to only listen for data coming through the Frame's rx characteristic, not all attached devices as before
    return rxChannel!.onValueReceived
        .where((event) => event[0] == 0x01)
        .map((event) {
      _log.finest(() => "Received data: ${event.sublist(1)}");
      return event.sublist(1);
    });
  }

  Future<void> disconnect() async {
    _log.info("Disconnecting");
    try {
      await device.disconnect();
    } catch (_) {}
  }

  Future<void> clearDisplay() async {
    _log.fine("Sending clearDisplay");
    await sendString(
        'frame.display.bitmap(1,1,4,2,15,"\\xFF") frame.display.show()',
        awaitResponse: false,
        log: false);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  Future<void> sendBreakSignal() async {
    _log.info("Sending break signal");
    await sendString("\x03", awaitResponse: false, log: false);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  Future<void> sendResetSignal() async {
    _log.info("Sending reset signal");
    await sendString("\x04", awaitResponse: false, log: false);
    await Future.delayed(const Duration(milliseconds: 100));
  }

  Future<String?> sendString(
    String string, {
    bool awaitResponse = true,
    bool log = true,
  }) async {
    try {
      if (log) {
        _log.info(() => "Sending string: $string");
      }

      if (state != BrilliantConnectionState.connected) {
        throw ("Device is not connected");
      }

      if (string.length > maxStringLength!) {
        throw ("Payload exceeds allowed length of $maxStringLength");
      }

      await txChannel!.write(utf8.encode(string), withoutResponse: true);

      if (awaitResponse == false) {
        return null;
      }

      final response = await rxChannel!.onValueReceived
          .timeout(const Duration(seconds: 10))
          .first;

      return utf8.decode(response);
    } catch (error) {
      _log.warning("Couldn't send string. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  Future<void> sendData(List<int> data) async {
    try {
      _log.finer(() => "Sending ${data.length} bytes of plain data");
      _log.finest(data);

      if (state != BrilliantConnectionState.connected) {
        throw ("Device is not connected");
      }

      if (data.length > maxDataLength!) {
        throw ("Payload exceeds allowed length of $maxDataLength");
      }

      var finalData = data.toList()..insert(0, 0x01);

      await txChannel!.write(finalData, withoutResponse: true);
    } catch (error) {
      _log.warning("Couldn't send data. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  /// Same as sendData but user includes the 0x01 header byte to avoid extra memory allocation
  Future<void> sendDataRaw(Uint8List data) async {
    try {
      _log.finer(() => "Sending ${data.length - 1} bytes of plain data");
      _log.finest(data);

      if (state != BrilliantConnectionState.connected) {
        throw ("Device is not connected");
      }

      if (data.length > maxDataLength! + 1) {
        throw ("Payload exceeds allowed length of ${maxDataLength! + 1}");
      }

      if (data[0] != 0x01) {
        throw ("Data packet missing 0x01 header");
      }

      // TODO check throughput difference using withoutResponse: false
      await txChannel!.write(data, withoutResponse: false);
    } catch (error) {
      _log.warning("Couldn't send data. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }

  /// Sends a typed message as a series of messages to Frame as chunks marked by
  /// [0x01 (dataFlag), messageFlag & 0xFF, {first packet: length(Uint16)}, payload(chunked)]
  /// until all data in the payload is sent. Payload data cannot exceed 65535 bytes in length.
  /// Can be received by a corresponding Lua function on Frame.
  Future<void> sendMessage(int msgCode, Uint8List payload) async {

    if (payload.length > 65535) {
      return Future.error(const BrilliantBluetoothException(
          'Payload length exceeds 65535 bytes'));
    }

    int lengthMsb = payload.length >> 8;
    int lengthLsb = payload.length & 0xFF;
    int sentBytes = 0;
    bool firstPacket = true;
    int bytesRemaining = payload.length;
    int chunksize = maxDataLength! - 1;

    // the full sized packet buffer to prepare. If we are sending a full sized packet,
    // set packetToSend to point to packetBuffer. If we are sending a smaller (final) packet,
    // instead point packetToSend to a range within packetBuffer
    Uint8List packetBuffer = Uint8List(maxDataLength! + 1);
    Uint8List packetToSend = packetBuffer;
    _log.fine(() => 'sendMessage: payload size: ${payload.length}');

    while (sentBytes < payload.length) {
      if (firstPacket) {
        _log.finer('sendMessage: first packet');
        firstPacket = false;

        if (bytesRemaining < chunksize - 2) {
          // first and final chunk - small payload
          _log.finer('sendMessage: first and final packet');
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer[2] = lengthMsb;
          packetBuffer[3] = lengthLsb;
          packetBuffer.setAll(
              4, payload.getRange(sentBytes, sentBytes + bytesRemaining));
          sentBytes += bytesRemaining;
          packetToSend =
              Uint8List.sublistView(packetBuffer, 0, bytesRemaining + 4);
        } else if (bytesRemaining == chunksize - 2) {
          // first and final chunk - small payload, exact packet size match
          _log.finer('sendMessage: first and final packet, exact match');
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer[2] = lengthMsb;
          packetBuffer[3] = lengthLsb;
          packetBuffer.setAll(
              4, payload.getRange(sentBytes, sentBytes + bytesRemaining));
          sentBytes += bytesRemaining;
          packetToSend = packetBuffer;
        } else {
          // first of many chunks
          _log.finer('sendMessage: first of many packets');
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer[2] = lengthMsb;
          packetBuffer[3] = lengthLsb;
          packetBuffer.setAll(
              4, payload.getRange(sentBytes, sentBytes + chunksize - 2));
          sentBytes += chunksize - 2;
          packetToSend = packetBuffer;
        }
      } else {
        // not the first packet
        if (bytesRemaining < chunksize) {
          _log.finer('sendMessage: not the first packet, final packet');
          // final data chunk, smaller than chunksize
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer.setAll(
              2, payload.getRange(sentBytes, sentBytes + bytesRemaining));
          sentBytes += bytesRemaining;
          packetToSend =
              Uint8List.sublistView(packetBuffer, 0, bytesRemaining + 2);
        } else {
          _log.finer(
              'sendMessage: not the first packet, non-final packet or exact match final packet');
          // non-final data chunk or final chunk with exact packet size match
          packetBuffer[0] = 0x01;
          packetBuffer[1] = msgCode & 0xFF;
          packetBuffer.setAll(
              2, payload.getRange(sentBytes, sentBytes + chunksize));
          sentBytes += chunksize;
          packetToSend = packetBuffer;
        }
      }

      // send the chunk
      await sendDataRaw(packetToSend);

      bytesRemaining = payload.length - sentBytes;
      _log.finer(() => 'Bytes remaining: $bytesRemaining');
    }
  }

  Future<void> uploadScript(String fileName, String fileContents) async {
    try {
      _log.info("Uploading script: $fileName");
      // TODO temporarily observe memory usage
      await sendString(
          'print("Frame Mem: " .. tostring(collectgarbage("count")))',
          awaitResponse: true);

      String file = fileContents;

      file = file.replaceAll('\\', '\\\\');
      file = file.replaceAll("\r\n", "\\n");
      file = file.replaceAll("\n", "\\n");
      file = file.replaceAll("'", "\\'");
      file = file.replaceAll('"', '\\"');

      var resp = await sendString(
          "f=frame.file.open('$fileName', 'w');print('\x02')",
          log: false);

      if (resp != "\x02") {
        throw ("Error opening file: $resp");
      }

      int index = 0;
      int chunkSize = maxStringLength! - 22;

      while (index < file.length) {
        // Don't go over the end of the string
        if (index + chunkSize > file.length) {
          chunkSize = file.length - index;
        }

        // Don't split on an escape character
        while (file[index + chunkSize - 1] == '\\') {
          chunkSize -= 1;
        }

        String chunk = file.substring(index, index + chunkSize);

        resp = await sendString("f:write('$chunk');print('\x02')", log: false);

        if (resp != "\x02") {
          throw ("Error writing file: $resp");
        }

        index += chunkSize;
      }

      resp = await sendString("f:close();print('\x02')", log: false);

      if (resp != "\x02") {
        throw ("Error closing file: $resp");
      }

      // TODO temporarily observe memory usage
      await sendString(
          'print("Frame Mem: " .. tostring(collectgarbage("count")))',
          awaitResponse: true);
    } catch (error) {
      _log.warning("Couldn't upload script. $error");
      return Future.error(BrilliantBluetoothException(error.toString()));
    }
  }
}

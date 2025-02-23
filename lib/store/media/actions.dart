import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:mime/mime.dart';
import 'package:redux/redux.dart';
import 'package:redux_thunk/redux_thunk.dart';

import 'package:syphon/global/libs/matrix/index.dart';
import 'package:syphon/storage/index.dart';
import 'package:syphon/store/alerts/actions.dart';
import 'package:syphon/store/index.dart';
import 'package:syphon/store/media/storage.dart';

class MediaStatus {
  static const FAILURE = 'failure';
  static const CHECKING = 'checking';
  static const SUCCESS = 'success';
}

class UpdateMediaChecks {
  final String? mxcUri;
  final String? status;

  UpdateMediaChecks({
    this.mxcUri,
    this.status,
  });
}

class UpdateMediaCache {
  final String? mxcUri;
  final Uint8List? data;

  UpdateMediaCache({
    this.mxcUri,
    this.data,
  });
}

ThunkAction<AppState> uploadMedia({
  File? localFile,
  String? mediaName = 'photo',
}) {
  return (Store<AppState> store) async {
    try {
      // Extension handling
      final String fileType = lookupMimeType(localFile!.path)!;
      final String fileExtension = fileType.split('/')[1];

      // Setting up params for upload
      final int fileLength = await localFile.length();
      final Stream<List<int>> fileStream = localFile.openRead();
      final String fileName = '$mediaName.$fileExtension';

      // Create request vars for upload
      final data = await MatrixApi.uploadMedia(
        protocol: store.state.authStore.protocol,
        accessToken: store.state.authStore.user.accessToken,
        homeserver: store.state.authStore.currentUser.homeserver,
        fileName: fileName,
        fileType: fileType,
        fileLength: fileLength,
        fileStream: fileStream,
      );
      // If upload fails, throw an error for the whole update
      if (data['errcode'] != null) {
        throw data['error'];
      }

      return data;
    } catch (error) {
      store.dispatch(
        addAlert(origin: 'uploadMedia', message: error.toString()),
      );
      return null;
    } finally {
      store.dispatch(SetLoading(loading: false));
    }
  };
}

ThunkAction<AppState> fetchThumbnail({String? mxcUri, double? size, bool force = false}) {
  return (Store<AppState> store) async {
    try {
      final mediaCache = store.state.mediaStore.mediaCache;
      final mediaChecks = store.state.mediaStore.mediaChecks;

      // Noop if already cached data
      if (mediaCache.containsKey(mxcUri) && !force) {
        return;
      }

      // Noop if currently checking or failed
      if (mediaChecks.containsKey(mxcUri) &&
          (mediaChecks[mxcUri!] == MediaStatus.CHECKING || mediaChecks[mxcUri] == MediaStatus.FAILURE) &&
          !force) {
        return;
      }

      store.dispatch(
        UpdateMediaChecks(mxcUri: mxcUri, status: MediaStatus.CHECKING),
      );

      // check if the media is only located in cold storage
      if (await checkMedia(mxcUri, storage: Storage.instance!)) {
        final storedData = await loadMedia(
          mxcUri: mxcUri,
          storage: Storage.instance!,
        );

        if (storedData != null) {
          store.dispatch(UpdateMediaCache(mxcUri: mxcUri, data: storedData));
          return;
        }
      }

      final params = {
        'protocol': store.state.authStore.protocol,
        'accessToken': store.state.authStore.user.accessToken,
        'homeserver': store.state.authStore.currentUser.homeserver,
        'mediaUri': mxcUri,
      };

      if (size != null) {
        params['size'] = size.toString();
      }

      final data = await compute(
        MatrixApi.fetchThumbnail,
        params,
      );

      final bodyBytes = data['bodyBytes'];

      store.dispatch(
        UpdateMediaCache(mxcUri: mxcUri, data: bodyBytes),
      );
      store.dispatch(
        UpdateMediaChecks(mxcUri: mxcUri, status: MediaStatus.SUCCESS),
      );
    } catch (error) {
      debugPrint('[fetchThumbnail] $mxcUri $error');
      store.dispatch(UpdateMediaChecks(
        mxcUri: mxcUri,
        status: MediaStatus.FAILURE,
      ));
    }
  };
}

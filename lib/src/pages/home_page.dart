import 'dart:async';

import 'package:flutter/material.dart';
import 'package:osmsgateway/src/prefs/prefs.dart';
import 'package:osmsgateway/src/providers/log_provider.dart';
import 'package:osmsgateway/src/queue/message_store.dart';
import 'package:osmsgateway/src/queue/sms_queue.dart';
import 'package:osmsgateway/src/server/server.dart';
import 'package:osmsgateway/src/sms/gateway_foreground.dart';
import 'package:osmsgateway/src/sms/native_sms_sender.dart';
import 'package:provider/provider.dart';
import 'package:connectivity/connectivity.dart';

class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Server server;
  final NativeSmsSender _sender = NativeSmsSender();
  late SmsQueue _queue;
  final GatewayForeground _foreground = NativeGatewayForeground();
  final String outputTex = '';
  PreferenciasUsuario preferencias = PreferenciasUsuario();

  late LogProvider _log;

  late StreamSubscription<ConnectivityResult> subscription;

  @override
  void initState() {
    super.initState();
    _queue = SmsQueue(
        sender: _sender,
        store: MessageStore.file(
            () async => '${await _sender.filesDir()}/sms_queue.json'));
    _applyQueuePrefs();
    _foreground
        .setKeepScreenOn(preferencias.keepScreenOn)
        .catchError((Object e) => _log.escribirLog(
            'No se pudo ajustar la pantalla siempre encendida: $e'));
    server = Server(queue: _queue);
    // La cola se recupera y sigue enviando aunque el servidor HTTP esté parado.
    _queue.start();
    subscription = Connectivity()
        .onConnectivityChanged
        .listen((ConnectivityResult result) async {
      if (result == ConnectivityResult.none) {
        _log.escribirLog('Se ha perdido la conexión wifi');
        await _parar();
      }
    });
  }

  void _applyQueuePrefs() {
    _queue.sendInterval = Duration(milliseconds: preferencias.sendIntervalMs);
    _queue.monthlyLimit = preferencias.monthlyLimit;
  }

  @override
  dispose() {
    super.dispose();
    subscription.cancel();
    _queue.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _log = Provider.of(context);
    server.addLogger(_log);
    return Scaffold(
      appBar: AppBar(
        title: Text('OSMSGateway'),
        actions: [
          IconButton(
              icon: Icon(Icons.delete_forever),
              onPressed: () {
                setState(() {
                  _log.limpiarLog();
                });
              })
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(20.0),
        child: Text(
          _log.getLog(),
          overflow: TextOverflow.visible,
        ),
      ),
      drawer: _crearDrawler(),
      floatingActionButton: _creaFloatinActionButton(context),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  _iniciar(BuildContext context) async {
    var connectivityResult = await (Connectivity().checkConnectivity());
    if (connectivityResult == ConnectivityResult.wifi) {
      if (!await _sender.hasPermission() &&
          !await _sender.requestPermission()) {
        _log.escribirLog(
            'Falta el permiso para enviar SMS; el servidor no se inicia');
        return;
      }
      try {
        await _foreground.ensureNotificationPermission();
      } catch (e) {
        _log.escribirLog('No se pudo pedir el permiso de notificaciones: $e');
      }
      _applyQueuePrefs();
      var args = {
        'serverChain': preferencias.serverChain,
        'serverKey': preferencias.serverKey,
        'timeout': preferencias.timeout,
        'tokenRequired': preferencias.tokenRequired,
        'token': preferencias.apiToken,
      };
      await server.iniciar(
          port: preferencias.puerto,
          secure: preferencias.secure,
          args: args); //InternetAddress.anyIPv4, preferencias.puerto);
      if (server.iniciado) {
        try {
          await _foreground.start(
              'Servidor activo en el puerto ${preferencias.puerto}');
        } catch (e) {
          _log.escribirLog('No se pudo iniciar el servicio en primer plano: '
              '$e. El servidor puede detenerse al cerrar la pantalla.');
        }
      }
    } else {
      _createDialog(context);
    }
  }

  _createDialog(BuildContext context) {
    return showDialog(
        context: context,
        builder: (BuildContext context) => AlertDialog(
              title: Text('Sin conexion'),
              content: Text(
                  'Es necesario activar la conexión WIFI, por favor, actívala antes de arrancar el servidor'),
              actions: [
                ElevatedButton(
                  child: Text('Cerrar'),
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                )
              ],
            ));
  }

  _parar() async {
    await server.parar();
    try {
      await _foreground.stop();
    } catch (e) {
      _log.escribirLog('No se pudo detener el servicio en primer plano: $e');
    }
  }

  Widget _creaFloatinActionButton(BuildContext context) {
    if (!server.iniciado) {
      return FloatingActionButton(
          child: Icon(Icons.play_arrow),
          onPressed: server.iniciado
              ? null
              : () {
                  setState(() {
                    _iniciar(context);
                  });
                });
    } else {
      return FloatingActionButton(
        child: Icon(Icons.stop),
        onPressed: (server.iniciado)
            ? () {
                setState(() {
                  _parar();
                });
              }
            : null,
      );
    }
  }

  Widget _crearDrawler() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            child: Center(
              child: Text(
                'Menu',
                style: TextStyle(fontSize: 50.0),
              ),
            ),
            decoration: BoxDecoration(color: Colors.teal),
          ),
          ListTile(
            leading: Icon(
              Icons.settings,
              color: Colors.blue,
            ),
            title: Text('Configuracion'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, 'prefs');
            },
          ),
          Divider(),
          AboutListTile(
            icon: const Icon(
              Icons.info,
              color: Colors.blue,
            ),
            applicationIcon: const FlutterLogo(),
            applicationName: 'OSMSGateway',
            applicationVersion: '1.0.0',
            applicationLegalese:
                'GNU GPLv3, creado por: José Miguel Manzano García',
          )
        ],
      ),
    );
  }
}

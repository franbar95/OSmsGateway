import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:osmsgateway/src/server/auth.dart';
import 'package:osmsgateway/src/sms/gateway_foreground.dart';
import 'package:osmsgateway/src/prefs/prefs.dart';
import 'package:osmsgateway/src/utils/utils.dart' as utils;
import 'package:file_picker/file_picker.dart';

class PrefsPage extends StatefulWidget {
  PrefsPage({Key? key}) : super(key: key);

  @override
  _PrefsPageState createState() => _PrefsPageState();
}

class _PrefsPageState extends State<PrefsPage> {
  PreferenciasUsuario preferencias = PreferenciasUsuario();
  final formKey = GlobalKey<FormState>();
  TextEditingController? _textController;
  TextEditingController? _textControllerTimeout;
  TextEditingController? _textControllerInterval;
  TextEditingController? _textControllerMonthly;
  int _port = 8080;
  int _timeout = 500;
  bool _temaOscuro = false;
  bool _isHttps = false;
  bool _tokenRequired = false;
  bool _keepScreenOn = true;
  @override
  void initState() {
    super.initState();
    _port = preferencias.puerto;
    _temaOscuro = preferencias.temaOscuro;
    _isHttps = preferencias.secure;
    _timeout = preferencias.timeout;
    _tokenRequired = preferencias.tokenRequired;
    _keepScreenOn = preferencias.keepScreenOn;
    _textController = new TextEditingController(text: _port.toString());
    _textControllerTimeout =
        new TextEditingController(text: _timeout.toString());
    _textControllerInterval = new TextEditingController(
        text: preferencias.sendIntervalMs.toString());
    _textControllerMonthly =
        new TextEditingController(text: preferencias.monthlyLimit.toString());
  }

  Future<void> _confirmRegenerate() async {
    final hasToken = preferencias.apiToken.isNotEmpty;
    final ok = !hasToken ||
        await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text('Generar nuevo token'),
                content: Text(
                    'El token actual dejará de funcionar y deberá actualizar '
                    'los sistemas que lo usan.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text('Cancelar')),
                  ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text('Generar')),
                ],
              ),
            ) ==
            true;
    if (ok) {
      setState(() {
        preferencias.apiToken = TokenAuth.generateToken();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
          title: Text('Configuracion'),
        ),
        body: Form(
          key: formKey,
          child: ListView(
            children: [
              Container(
                padding: EdgeInsets.all(5.0),
                child: Text(
                  'Configuracion',
                  style: TextStyle(fontSize: 40.0, fontWeight: FontWeight.bold),
                ),
              ),
              Divider(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 20.0),
                child: TextFormField(
                  keyboardType: TextInputType.number,
                  controller: _textController,
                  decoration: InputDecoration(
                      labelText: 'Puerto', helperText: 'Puerto de conexión'),
                  onChanged: (value) {
                    if (utils.isNumeric(value)) {
                      preferencias.puerto = int.parse(value);
                      setState(() {
                        _port = int.parse(value);
                      });
                    }
                  },
                  validator: (value) {
                    print(value);
                    if (utils.isNumeric(value!)) {
                      return null;
                    } else {
                      return 'Solo números';
                    }
                  },
                ),
              ),
              Divider(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 20.0),
                child: TextFormField(
                  keyboardType: TextInputType.number,
                  controller: _textControllerTimeout,
                  decoration: InputDecoration(
                      labelText: 'Timeout',
                      helperText:
                          'Timeout de petición en milisegundos, minimo 200'),
                  onChanged: (value) {
                    if (utils.isNumeric(value)) {
                      var t = int.parse(value);
                      if (t <= 200) {
                        t = 200;
                        value = "200";
                      }
                      preferencias.timeout = t;
                      setState(() {
                        _timeout = t;
                      });
                    }
                  },
                  validator: (value) {
                    print(value);
                    if (utils.isNumeric(value!)) {
                      return null;
                    } else {
                      return 'Solo números';
                    }
                  },
                ),
              ),
              Divider(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 20.0),
                child: TextFormField(
                  keyboardType: TextInputType.number,
                  controller: _textControllerInterval,
                  decoration: InputDecoration(
                      labelText: 'Pausa entre SMS (ms)',
                      helperText:
                          'Mínimo 1000. Evita ráfagas y los límites de Android'),
                  onChanged: (value) {
                    if (utils.isNumeric(value)) {
                      var t = int.parse(value);
                      if (t >= 1000) preferencias.sendIntervalMs = t;
                    }
                  },
                ),
              ),
              Divider(),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 20.0),
                child: TextFormField(
                  keyboardType: TextInputType.number,
                  controller: _textControllerMonthly,
                  decoration: InputDecoration(
                      labelText: 'Límite mensual de SMS',
                      helperText: '0 = sin límite. Protege ante errores del cliente'),
                  onChanged: (value) {
                    if (utils.isNumeric(value)) {
                      var t = int.parse(value);
                      if (t >= 0) preferencias.monthlyLimit = t;
                    }
                  },
                ),
              ),
              Divider(),
              SwitchListTile(
                title: Text('Servidor HTTPS: '),
                value: _isHttps,
                onChanged: (value) {
                  preferencias.secure = value;
                  setState(() {
                    _isHttps = value;
                  });
                },
              ),
              Divider(),
              SwitchListTile(
                title: Text('Exigir token de acceso'),
                subtitle: Text(_tokenRequired
                    ? 'Las peticiones deben enviar Authorization: Bearer <token>. '
                        'Se aplica al reiniciar el servidor.'
                    : 'Desactivado: cualquier equipo de la red puede enviar SMS.'),
                value: _tokenRequired,
                onChanged: (value) {
                  if (value && preferencias.apiToken.isEmpty) {
                    preferencias.apiToken = TokenAuth.generateToken();
                  }
                  preferencias.tokenRequired = value;
                  setState(() {
                    _tokenRequired = value;
                  });
                },
              ),
              ListTile(
                leading: Icon(Icons.pin),
                title: Text('Token de acceso'),
                subtitle: Text(preferencias.apiToken.isEmpty
                    ? 'Sin token. Toque para generar uno.'
                    : preferencias.apiToken),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.copy),
                      tooltip: 'Copiar',
                      onPressed: preferencias.apiToken.isEmpty
                          ? null
                          : () async {
                              await Clipboard.setData(
                                  ClipboardData(text: preferencias.apiToken));
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Token copiado')));
                            },
                    ),
                    IconButton(
                      icon: Icon(Icons.refresh),
                      tooltip: 'Generar uno nuevo',
                      onPressed: _confirmRegenerate,
                    ),
                  ],
                ),
                onTap: preferencias.apiToken.isEmpty ? _confirmRegenerate : null,
              ),
              Divider(),
              SwitchListTile(
                title: Text('Mantener la pantalla encendida'),
                subtitle: Text('Mientras la app está abierta, para que el '
                    'teléfono no se suspenda y el servidor siga respondiendo.'),
                value: _keepScreenOn,
                onChanged: (value) {
                  preferencias.keepScreenOn = value;
                  NativeGatewayForeground().setKeepScreenOn(value);
                  setState(() {
                    _keepScreenOn = value;
                  });
                },
              ),
              Divider(),
              SwitchListTile(
                title: Text('Tema oscuro: '),
                value: _temaOscuro,
                onChanged: (value) {
                  preferencias.temaOscuro = value;
                  setState(() {
                    _temaOscuro = value;
                  });
                },
              ),
              Divider(),
              ListTile(
                leading: Icon(Icons.security),
                title: Text('Server Chain'),
                subtitle: Text(preferencias.serverChain),
                onTap: () async {
                  FilePickerResult? result =
                      await FilePicker.platform.pickFiles();

                  if (result != null) {
                    File file = File(result.files.single.path ?? '');
                    preferencias.serverChain = file.path;
                  } else {
                    // User canceled the picker
                  }
                  setState(() {});
                },
              ),
              Divider(),
              ListTile(
                leading: Icon(Icons.vpn_key),
                title: Text('Server key'),
                subtitle: Text(preferencias.serverKey),
                onTap: () async {
                  FilePickerResult? result =
                      await FilePicker.platform.pickFiles();

                  if (result != null) {
                    File file = File(result.files.single.path ?? '');
                    preferencias.serverKey = file.path;
                  } else {
                    // User canceled the picker
                  }
                  setState(() {});
                },
              ),
            ],
          ),
        ));
  }
}

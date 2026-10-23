# Rnote Mobile

Pizarra digital para iOS y Android, escrita en Flutter, que lee y escribe archivos `.rnote`
compatibles con [Rnote](https://rnote.flxzt.net) de escritorio.

## Funciones

- **Formato `.rnote` nativo**: abre archivos de Rnote 0.5.9 en adelante y guarda en el formato de
  Rnote 0.15 (o, opcionalmente, en el de 0.13/0.14 para versiones estables antiguas). Los trazos que
  no se modifican se guardan tal cual, así no se pierde nada que la app no entienda.
- **Herramientas**: lápiz (liso o texturizado, curvas de presión de Rnote), resaltador (capa de
  resaltado con fusión multiplicativa como en Rnote), borrador (trazos completos o partes),
  selección (lazo o rectángulo: mover, escalar, duplicar, recolorear, borrar), formas (línea,
  flecha, rectángulo, elipse; trazo discontinuo y relleno), texto e imágenes (PNG/JPG/SVG).
- **Documentos**: diseños infinito, semi-infinito, vertical continuo y páginas fijas; formatos A6–A3,
  Carta y Oficio; fondos con color y patrones (líneas, cuadrícula, puntos, isométricos).
- **Menús desplegables y autoocultables**: barra superior y barra de herramientas flotantes que se
  ocultan al dibujar y tras un tiempo de inactividad; quedan un tirador y una burbuja con la
  herramienta actual para traerlas de vuelta. Se pueden fijar, colapsar y mover a la derecha.
- **Tabletas y lápices**: presión normalizada (Apple Pencil, S Pen, Wacom/USI…), sensibilidad
  ajustable, suavizado, botones laterales y extremo borrador configurables, cursor al pasar el lápiz
  por encima, rechazo de palma, modo "el dedo sólo navega", ratón y trackpad.
- **Gestos**: dos dedos desplazan y hacen zoom, tocar con dos dedos deshace, con tres rehace.
- **Sincronización con el PC** por WebDAV (ver abajo), importación/exportación de `.rnote`,
  exportación a PNG, abrir `.rnote` desde otras apps y, en iOS, carpeta visible en la app Archivos.

## Compilar

```sh
cd mobile
flutter pub get
flutter run                      # dispositivo o emulador conectado
flutter build apk --release      # Android
flutter build ipa                # iOS (requiere firma en Xcode)
```

Tests (`flutter test`): formato de archivo (incluye un round-trip de los archivos de prueba de
`../misc`), sincronización contra el servidor de `tools/`, entrada de lápiz y capturas del editor.
Con `RNOTE_TEST_OUT=<carpeta>` los tests escriben los `.rnote` generados y las capturas; los
`.rnote` se pueden validar con `rnote-cli test <carpeta>/*.rnote`.

## Sincronizar con Rnote en el PC

La app sincroniza su biblioteca en ambos sentidos con una carpeta WebDAV. Rnote de escritorio
trabaja directamente sobre esa carpeta. Cambios en un solo lado se copian al otro; si un documento
cambió en ambos, se guardan las dos versiones (la del móvil como "… (conflicto móvil …).rnote").
Los borrados también se propagan.

### Opción 1: script incluido (red local, sin instalar nada)

En el PC, con Python 3:

```sh
python3 mobile/tools/rnote_sync_server.py ~/Documentos/Rnote --user yo --password secreto
```

El script muestra la URL (p. ej. `http://192.168.1.10:8080/`). En la app: Ajustes →
Sincronización con el PC → URL, usuario y contraseña → *Probar conexión*. El PC y el móvil deben
estar en la misma red, y el puerto 8080 permitido en el cortafuegos del PC.

### Opción 2: Nextcloud / ownCloud / NAS

Usa la URL WebDAV de una carpeta, p. ej.
`https://mi-nube/remote.php/dav/files/USUARIO/Rnote/`, con una contraseña de aplicación. En el PC,
el cliente de Nextcloud mantiene la carpeta sincronizada y Rnote la abre directamente.

### Opción 3: rclone

```sh
rclone serve webdav ~/Documentos/Rnote --addr :8080 --user yo --pass secreto
```

## Limitaciones conocidas

- Los estilos *rugoso* de Rnote se muestran lisos y el *texturizado* es una aproximación; los
  archivos conservan el estilo original y se ven bien en el PC.
- Sin importación de PDF (las páginas PDF importadas en el PC sí se muestran, son imágenes SVG).
- La sincronización sólo considera los `.rnote` de la carpeta raíz (sin subcarpetas).
- En iOS no hay acceso al doble toque / apretar del Apple Pencil (Flutter no lo expone).

<h1 align="center">
  <a href="https://db-ol.github.io/Orra/"><img src="site/icon.png" alt="Orra" width="64" valign="middle"></a> Orra
</h1>

<p align="center">
  <a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><img src="https://img.shields.io/badge/descargar-Orra.dmg-0A84FF?logo=apple&logoColor=white" alt="Descargar Orra.dmg"></a>
  <a href="https://db-ol.github.io/Orra/"><img src="https://img.shields.io/badge/sitio%20web-db--ol.github.io%2FOrra-555555?logo=safari&logoColor=white" alt="Sitio web de Orra"></a>
  <a href="https://github.com/db-ol/Orra/releases"><img src="https://img.shields.io/github/v/release/db-ol/Orra?label=versi%C3%B3n&color=0A84FF" alt="Última versión"></a>
</p>

<p align="center"><sub><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.ja.md">日本語</a> · Español</sub></p>

<p align="center">
  <strong>Dictado por voz de código abierto para la Mac.</strong><br>
  Presiona una tecla, habla, vuelve a presionarla y tus palabras aparecen en la app en la que estás escribiendo.<br>
  Tu voz se convierte en texto en tu propia Mac, nunca en un servidor.
</p>

<h3 align="center"><a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><ins>Descargar Orra</ins></a></h3>

<p align="center"><sub>Para computadoras Mac con Apple Chip y macOS 15.6 o posterior. Orra es una versión preliminar. Todavía tiene detalles por pulir, y su diseño va a cambiar.</sub></p>

## Funciones

<table>
<tr>
<td width="50%" valign="middle">

### Dictado en cualquier app

Habla en chino (mandarín y cantonés), en inglés o en los dos mezclados en la misma oración. En Idioma de dictado, en Configuración, puedes elegir en su lugar japonés o español con inglés, en beta. El modelo Qwen3-ASR 1.7B lo transcribe en tu Mac y Orra lo pega donde está el cursor. Las muletillas como 呃, um y uh desaparecen, y los números dichos en chino, como fechas, precios y porcentajes, se escriben con cifras.

</td>
<td width="50%"><img src="docs/images/readme/en/dictation.gif" alt="Con la tecla para hablar presionada, alguien dice “Um, I’ll post Wednesday’s meeting notes this afternoon.” Las barras de la cápsula de Orra se mueven con la voz, y la oración aparece en una nota sin el um." width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Tus palabras, como tú las escribes

Un vocabulario personal de hasta 5,000 nombres y términos, para que Orra los escriba como tú. Si activas el aprendizaje, Orra aprende de las palabras que corriges justo después de un dictado y la próxima vez las escribe bien.

</td>
<td width="50%"><img src="docs/images/readme/en/vocabulary.gif" alt="Una nota dice “We tested Ora on the new build.” Alguien cambia Ora por Orra, y Orra muestra un aviso: Se agregó “Orra” al Vocabulario, Se oyó como “Ora”, con Deshacer. El siguiente dictado escribe Orra." width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Limpieza con un modelo local

Opcional. Un modelo de texto en tu Mac elimina las muletillas que las reglas dejan pasar y aplica las rectificaciones que haces al hablar, así que “at three, oh wait, four” queda como “at four”. Pegar texto original siempre recupera lo que dijiste.

</td>
<td width="50%"><img src="docs/images/readme/en/cleanup.gif" alt="Con Limpiar texto activado, alguien dice “Let’s go over the quote at three, oh wait, four tomorrow.” En el correo queda “Let’s go over the quote at four tomorrow.”" width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Tecla de traducción

Opcional. Mantén presionada una segunda tecla y Orra pega lo que dices traducido entre chino e inglés, con el mismo modelo en tu Mac. Una pequeña marca 译 indica que ese dictado se va a traducir.

</td>
<td width="50%"><img src="docs/images/readme/en/translation.gif" alt="En un chat, Sam pregunta “When can I see the designs?” Con la tecla de traducción presionada, alguien dice 我这边周五之前能把设计稿发给你. La cápsula muestra la marca 译, y “I can send you the designs before Friday.” aparece en el campo del mensaje." width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Interpretación en reuniones

Para reuniones en distintos idiomas. Lee en tu idioma lo que dicen los demás y deja que te escuchen en el suyo, incluso con tu propia voz. **Subtítulos en vivo** muestra lo que reproduce la Mac, como una llamada, en forma de subtítulos traducidos en una ventana flotante. **Leer traducciones a los demás** lee en voz alta lo que dijiste con la tecla de traducción, con un modelo de síntesis de voz en tu Mac, y lo envía al dispositivo virtual Orra Microphone, para que la otra persona de la llamada escuche tus palabras en su idioma.

Novedad de la versión 0.4.0.

</td>
<td width="50%"><img src="docs/images/readme/en/meeting.gif" alt="En una videollamada, Alex habla en inglés y la ventana de Subtítulos en vivo muestra cada oración con su traducción al chino. Luego, el usuario mantiene presionada la tecla de traducción y dice 可以，我周三之前把测试做完, y en la llamada se escucha “Sure, I’ll finish testing by Wednesday.” desde Orra Microphone." width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### Actualizaciones desde la app

Orra solo busca una versión nueva después de que se lo permites, y solo la instala cuando tú lo decides. Todas las actualizaciones están firmadas.

</td>
<td width="50%"><img src="docs/images/readme/en/updates.gif" alt="El menú de Orra en la barra de menús, con Buscar actualizaciones seleccionado. Una ventana ofrece la versión nueva, la descarga y ofrece Instalar y volver a abrir." width="100%"></td>
</tr>
</table>

## Instalación

- **[Descarga Orra.dmg](https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg)**, la versión más reciente, ábrelo y arrastra Orra a la carpeta Aplicaciones. Las versiones anteriores y las notas de la versión están en [la página de versiones](https://github.com/db-ol/Orra/releases).
- **Orra Microphone**, opcional, para Leer traducciones a los demás: descarga [OrraMicrophone.pkg](https://github.com/db-ol/Orra/releases/download/v0.4.0/OrraMicrophone.pkg), firmado y notariado, y ábrelo para instalarlo. [Drivers/OrraMicrophone](Drivers/OrraMicrophone/README.md) (en inglés) explica cómo quitarlo o compilarlo por tu cuenta.
- Requiere una Mac con Apple Chip y macOS 15.6 o posterior, y unos 3 GB de espacio disponible en el disco, más 2.8 GB para el modelo local opcional, que limpia y traduce, y unos 2 GB para el modelo de síntesis de voz opcional de Leer traducciones a los demás.
- La app está firmada con un Developer ID y notariada por Apple, así que se abre sin advertencias.
- No está en la Mac App Store, porque el entorno aislado (sandbox) de la App Store no permite que una app detecte una tecla en otras apps ni pegue texto en ellas.

Al abrir Orra, una ventana de bienvenida te guía para descargar los modelos, permitir el acceso al micrófono y a Accesibilidad, y elegir tu tecla para hablar y cómo funciona. La [guía del usuario](docs/user-guide.es.md) explica cada función y su configuración.

## Privacidad

Orra convierte tu voz en texto en tu Mac y nunca envía tus grabaciones ni su texto a ningún lado. No tiene cuentas, ni estadísticas de uso, ni servidor propio. Solo se conecta a Internet para descargar los modelos que pides y, una vez que lo permites, para buscar actualizaciones. Las funciones que guardan algo, como Aprender de mis correcciones y Recordar mi voz, están desactivadas hasta que las activas.

[docs/privacy.es.md](docs/privacy.es.md) detalla qué guarda Orra, cuándo se conecta a Internet y cómo eliminar los modelos.

## Comunidad y soporte

- **Reporta un problema.** Selecciona Reportar un problema… en el menú de Orra o [abre un issue en GitHub](https://github.com/db-ol/Orra/issues/new/choose). Por favor, no incluyas nada privado que hayas dictado.
- **Preguntas e ideas.** Pregunta en [Discussions](https://github.com/db-ol/Orra/discussions).
- **WeChat.** Escanea el código para unirte al grupo de Orra en WeChat.<br>
  <img src="docs/images/wechat-group.png" alt="Código QR del grupo de Orra en WeChat" width="160">
- **Apoya el proyecto.** Si Orra te resulta útil, [dale una estrella en GitHub](https://github.com/db-ol/Orra).

## Para desarrolladores

El código de Orra está escrito en Swift y SwiftUI. [docs/development.md](docs/development.md) (en inglés) explica cómo compilar y probar Orra, cómo está organizado el código y cómo se publican las versiones. Lee [AGENTS.md](AGENTS.md) antes de modificar el código.

## Licencia

MIT. Consulta [LICENSE](LICENSE).

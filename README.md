# Halo Color

**Un borde luminoso para la ventana activa de macOS, con un color propio para cada app.**

Halo Color es una aplicación de barra de menús basada en [Halo](https://github.com/akira-toriyama/halo). Sigue la ventana activa, aplica el color que hayas elegido para su aplicación y usa un color de respaldo para las demás. Los ajustes se guardan y se aplican automáticamente.

## Qué puedes configurar

| Opción | Qué hace |
| --- | --- |
| Colores por app | Las apps se registran al enfocarlas por primera vez con un color distinto. Puedes cambiarlo con un color rápido, el selector o un valor hexadecimal. |
| Borde | Escoge entre redondeado, recto, guiones y puntos; ajusta grosor y glow. |
| Efecto | Elige ninguno, Pac-Man, fantasma, chispa o cometa. El efecto recorre el borde sin sustituir el color asignado. |
| Cambio de foco | Destello, nombre de la app durante dos segundos, sacudida opcional y sonido del sistema opcional con volumen ajustable. |
| Ventanas sin foco | Controla con un deslizador cuánto se oscurecen. |
| Inicio de sesión | Activa o desactiva el arranque automático. |

La ventana de ajustes tiene vistas previas interactivas del borde y el efecto. Puedes ver el color de respaldo o el de cualquier app de tu lista. El menú de la barra muestra todas las apps registradas con su color; pulsa una para abrir directamente su edición. La propia ventana de ajustes también recibe el borde mientras Halo Color está activo.

## Requisitos

- macOS 26 o posterior.
- Apple Silicon y Xcode con Swift 6 para compilar desde el código fuente.
- La sacudida de ventanas requiere el permiso de **Accesibilidad**. Las demás opciones no lo necesitan.

## Instalar desde el código fuente

```sh
git clone https://github.com/eric21dev/HaloColor.git
cd HaloColor
./package.sh
open HaloColor.app
```

`package.sh` crea `HaloColor.app` en la carpeta del proyecto y la firma localmente. La app vive en la barra de menús; abre **Colores por app…** para configurarla. Cierra otras instancias de Halo antes de abrir Halo Color para evitar dos bordes superpuestos.

El paquete compilado localmente usa una firma ad hoc. macOS puede pedirte confirmar su primera apertura. Si activas la sacudida, concede Accesibilidad a Halo Color en **Ajustes del Sistema → Privacidad y seguridad → Accesibilidad**.

## Uso

1. Abre **Colores por app…** desde la barra de menús.
2. Enfoca cualquier app nueva: Halo Color la añadirá con un color libre. También puedes usar **Añadir app…** y seleccionar un archivo `.app`.
3. Abre **Apps registradas** en el menú de la barra y pulsa una app para cambiar su color. En Ajustes puedes elegir un color rápido o usar el selector. También puedes cambiar el color de respaldo.
4. Prueba los estilos y efectos en la vista previa. Los cambios se aplican sin botón de guardar.

El sonido está desactivado por defecto. Actívalo en **Detalles y cambio de foco**, elige un sonido del sistema y ajusta su volumen con el deslizador. El botón ▶︎ reproduce una muestra al volumen elegido.

Los colores se asocian al identificador de paquete de cada aplicación. Si una app no tiene color asignado, usa el color de respaldo. Halo Color lee y actualiza `~/.config/halo/config.toml`, de modo que puedes editar la configuración también a mano:

```toml
[border]
color = "#39C5C8"
style = "rounded" # rounded | square | dashed | dotted
glow = true
width = 3

[app-colors]
apps = [
  "com.apple.Terminal=#28D98A",
  "com.google.Chrome=#F4C542",
]

[pets]
effect = "spark" # none | chomp | ghost | spark | comet
```

Consulta [config.toml](config.toml) para más opciones. Los cambios del archivo se recargan en vivo.

## Código y créditos

Halo Color adapta el proyecto [akira-toriyama/halo](https://github.com/akira-toriyama/halo) y usa sus dependencias [sill](https://github.com/akira-toriyama/sill) y [swift-toml-edit](https://github.com/akira-toriyama/swift-toml-edit). Se conserva el aviso de copyright original en [LICENSE](LICENSE). El proyecto se distribuye bajo licencia MIT.

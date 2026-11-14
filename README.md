# Coche robot: modo ROS 2 del simulador web

El simulador del karting corre en el navegador (MuJoCo en WebAssembly). En su modo **ROS 2**
(tecla **Esc** → ROS 2) el coche lo conduce un nodo de ROS 2 de verdad, que habla con la web a
través de [rosbridge](https://github.com/RobotWebTools/rosbridge_suite) en `ws://127.0.0.1:9090`.
Este repositorio trae lo necesario para eso: el script que lo arranca todo, un piloto de ejemplo
y el modelo del coche para RViz.

## Arrancarlo (Linux; en Windows, dentro de WSL)

```bash
wget -qO- https://raw.githubusercontent.com/simonllopez/coche-robot-ros2/main/instalar.sh | bash
```

Lo descarga en `~/coche-robot-ros2` y ejecuta `conectar.sh`. Por defecto **no conduce nadie**: arranca rosbridge,
el republicador de la cámara y el modelo para RViz, y el coche espera a que tu nodo publique en `/cmd_vel`.
Para probarlo con el teclado: `ros2 run teleop_twist_keyboard teleop_twist_keyboard` (con Docker, dentro del
contenedor: ver más abajo).
`conectar.sh` elige solo dónde correr:

- **Tienes ROS 2** (`/opt/ros/<distro>`): lo usa, comprueba que están rosbridge,
  `robot_state_publisher` e `image_transport` (con sus plugins) y, si falta algo, te ofrece instalarlo con `apt`.
- **No tienes ROS 2 pero sí Docker**: crea una imagen con ROS 2 Jazzy (solo la primera vez, unos minutos)
  y lo corre todo dentro. Solo se abre el puerto 9090 en `127.0.0.1`.
- **Ninguno de los dos**: te dice cómo instalar Docker o ROS 2.

Cuando pone *Listo*, vuelve a la web: si ya estabas en la guía de ROS 2, se conecta sola. La primera vez,
el navegador pide permiso para **acceder a apps y servicios de este dispositivo** (red local): acéptalo, es
lo que deja a la página hablar con rosbridge en `127.0.0.1`. Si lo rechazaste, se vuelve a activar en el
icono de la izquierda de la barra de direcciones → *Configuración del sitio* → *Acceso a la red local*.

Las siguientes veces:

```bash
cd ~/coche-robot-ros2
./conectar.sh                    # solo el puente: rosbridge + cámara + modelo (tu nodo, en otra terminal)
./conectar.sh piloto_ros2.py     # además, el piloto de ejemplo
./conectar.sh mi_piloto.py       # además, tu piloto
./conectar.sh --slam             # además, el mapa con slam_toolbox (topic /map)
./conectar.sh --rviz             # además, RViz (con --slam, también el mapa)
./conectar.sh --slam --rviz piloto_ros2.py   # todo junto: el piloto da vueltas y ves cómo se hace el mapa
./conectar.sh --docker           # usar Docker aunque tengas ROS 2
ROS_DOMAIN_ID=43 ./conectar.sh   # separado de otras cosas de ROS que tengas abiertas
```

Ctrl+C lo cierra todo. Con Docker, ROS 2 vive dentro del contenedor, así que tu nodo también tiene que correr
ahí. La carpeta está montada en `/coche` (tus cambios se ven sin reconstruir nada):

```bash
docker exec -it coche-robot-ros2 bash -c 'source /opt/ros/jazzy/setup.bash && cd /coche && python3 mi_piloto.py'
```

Con el teclado, dentro del contenedor:

```bash
docker exec -it coche-robot-ros2 bash -c 'source /opt/ros/jazzy/setup.bash && ros2 run teleop_twist_keyboard teleop_twist_keyboard'
```

## Mapa con slam_toolbox

`--slam` lanza dos cosas:

- `slam/scan_slam.py`: republica `/scan` en `/scan_slam` con los ángulos de −π a π (slam_toolbox no entiende
  los de 0 a 2π que publica el simulador).
- slam_toolbox con `slam/slam.yaml`: ajustado al karting (`base_frame: base_link`, `use_sim_time: true`,
  celdas de 2,5 cm). Con la configuración por defecto de slam_toolbox no funciona: busca `base_footprint` y
  usa el reloj del PC en vez del simulado (*Failed to compute odom pose*).

Para guardar el mapa: `ros2 service call /slam_toolbox/save_map slam_toolbox/srv/SaveMap "{name: {data: mapa}}"`.
RViz con el mapa: `rviz/coche_mapa.rviz` (lo abre `--rviz` si va con `--slam`).

Con Docker, `--rviz` abre la ventana de RViz desde el contenedor en tu escritorio (X11, o XWayland en Wayland;
hace falta `xauth`).

## Qué publica y qué espera la web

| Tema | Tipo | |
|---|---|---|
| `/clock` | `rosgraph_msgs/Clock` | tiempo simulado (usa `use_sim_time`) |
| `/odom` | `nav_msgs/Odometry` | velocidad y giro con ruido de semilla fija; la posición deriva |
| `/tf` | `tf2_msgs/TFMessage` | `odom → base_link` |
| `/scan` | `sensor_msgs/LaserScan` | LiDAR a 20 Hz: la señal de "te toca" |
| `/camara/image_raw/compressed` | `sensor_msgs/CompressedImage` | JPEG 320×180, 10 Hz (`conectar.sh` la republica sin comprimir en `/camara/image_raw`) |
| `/cmd_vel` | `geometry_msgs/Twist` | `linear.x` (m/s) y `angular.z` (rad/s); en modo síncrono, **una** por cada `/scan` |
| `/reiniciar_simulacion` | `std_srvs/Trigger` | vuelve a la salida |

La web tiene dos modos (menú **Esc** → *Sincronía en ROS 2*):

- **Tiempo real** (por defecto): la simulación corre sola y usa la última orden de `/cmd_vel`; si no llega
  ninguna en 1 s, el coche se para. Sirve para `teleop_twist_keyboard` y cualquier nodo con su propio temporizador.
- **Síncrono** (como el reto): publica `/scan` y espera **una** orden en `/cmd_vel` antes de avanzar 50 ms, así que
  el resultado no depende de lo rápido que sea tu PC. Un nodo que no responde a cada `/scan` deja el coche congelado.

## Archivos

| Archivo | Qué es |
|---|---|
| `instalar.sh` | descarga este repositorio y arranca `conectar.sh` |
| `conectar.sh` | rosbridge, republicador de la cámara, `robot_state_publisher` y el piloto (con tu ROS 2 o con Docker) |
| `piloto_ros2.py` | piloto con LiDAR y odometría ("extensor de discontinuidades"), ~26 s por vuelta |
| `ejemplo_piloto.py` | piloto mínimo: la plantilla para empezar el tuyo |
| `rviz/` | modelo del coche (`coche.urdf`) y vistas de RViz: `coche.rviz` y `coche_mapa.rviz` (con el mapa) |
| `slam/` | `slam.yaml` (slam_toolbox ajustado al karting) y `scan_slam.py` (el `/scan` de −π a π) |
| `Dockerfile` | ROS 2 Jazzy con rosbridge e image_transport (lo usa `conectar.sh`) |

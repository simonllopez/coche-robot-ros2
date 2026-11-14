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
./conectar.sh --docker           # usar Docker aunque tengas ROS 2
ROS_DOMAIN_ID=43 ./conectar.sh   # separado de otras cosas de ROS que tengas abiertas
```

Ctrl+C lo cierra todo. Con Docker, ROS 2 vive dentro del contenedor, así que tu nodo también tiene que correr
ahí. La carpeta está montada en `/coche` (tus cambios se ven sin reconstruir nada):

```bash
docker exec -it coche-robot-ros2 bash -c 'source /opt/ros/jazzy/setup.bash && cd /coche && python3 mi_piloto.py'
```

## Qué publica y qué espera la web

| Tema | Tipo | |
|---|---|---|
| `/clock` | `rosgraph_msgs/Clock` | tiempo simulado (usa `use_sim_time`) |
| `/odom` | `nav_msgs/Odometry` | velocidad y giro con ruido de semilla fija; la posición deriva |
| `/tf` | `tf2_msgs/TFMessage` | `odom → base_link` |
| `/scan` | `sensor_msgs/LaserScan` | LiDAR a 20 Hz: la señal de "te toca" |
| `/camara/image_raw/compressed` | `sensor_msgs/CompressedImage` | JPEG 320×180, 10 Hz (`conectar.sh` la republica sin comprimir en `/camara/image_raw`) |
| `/cmd_vel` | `geometry_msgs/Twist` | **una** orden por cada `/scan`: `linear.x` (m/s) y `angular.z` (rad/s) |
| `/reiniciar_simulacion` | `std_srvs/Trigger` | vuelve a la salida |

La simulación espera a tu orden antes de avanzar 50 ms, así que el resultado no depende de lo rápido que sea tu PC.

## Archivos

| Archivo | Qué es |
|---|---|
| `instalar.sh` | descarga este repositorio y arranca `conectar.sh` |
| `conectar.sh` | rosbridge, republicador de la cámara, `robot_state_publisher` y el piloto (con tu ROS 2 o con Docker) |
| `piloto_ros2.py` | piloto con LiDAR y odometría ("extensor de discontinuidades"), ~26 s por vuelta |
| `ejemplo_piloto.py` | piloto mínimo: la plantilla para empezar el tuyo |
| `rviz/` | modelo del coche (`coche.urdf`) y vista de RViz: `rviz2 -d rviz/coche.rviz --ros-args -p use_sim_time:=true` |
| `Dockerfile` | ROS 2 Jazzy con rosbridge e image_transport (lo usa `conectar.sh`) |

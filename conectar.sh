#!/bin/bash
# Conecta el simulador web del coche robot (modo ROS 2) con ROS 2 de verdad.
#
#   ./conectar.sh                    solo lo necesario: rosbridge + cámara + modelo para RViz (sin piloto:
#                                    el coche espera a que tu nodo publique en /cmd_vel)
#   ./conectar.sh piloto_ros2.py     además, lanza un piloto (el de ejemplo o el tuyo)
#   ./conectar.sh --slam             además, hace el mapa con slam_toolbox (topic /map)
#   ./conectar.sh --rviz             además, abre RViz (con el mapa si va con --slam)
#   ./conectar.sh --nav --rviz       navegar con Nav2 sobre el mapa del circuito (nav/): destinos con RViz
#   ./conectar.sh --docker           todo dentro de Docker (no hace falta tener ROS 2)
#   ROS_DOMAIN_ID=43 ./conectar.sh   separado de otras cosas de ROS que tengas abiertas
#
# Si tienes ROS 2 instalado (/opt/ros/<distro>) lo usa; si no, y tienes Docker, usa Docker.
# Luego, en la web: Esc -> ROS 2. Ctrl+C lo cierra todo.

set -e
cd "$(dirname "$0")"

USAR_DOCKER=0
PILOTO=""
SLAM=0
RVIZ=0
NAV=0
for a in "$@"; do
  case "$a" in
    --docker) USAR_DOCKER=1 ;;
    --sin-piloto) PILOTO="" ;;            # (lo que hace ya sin argumentos; se mantiene por compatibilidad)
    --slam) SLAM=1 ;;
    --rviz) RVIZ=1 ;;
    --nav) NAV=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) PILOTO="$a" ;;
  esac
done
[ -n "$PILOTO" ] && [ ! -f "$PILOTO" ] && { echo "No encuentro el piloto: $PILOTO"; exit 1; }
[ "$NAV" = 1 ] && [ "$SLAM" = 1 ] && { echo "--nav usa el mapa ya hecho (nav/mapa.yaml): no se junta con --slam."; exit 1; }
[ "$NAV" = 1 ] && [ -n "$PILOTO" ] && { echo "Con --nav conduce Nav2: no lances también un piloto."; exit 1; }

PUERTO="${ROSBRIDGE_PUERTO:-9090}"
DIRECCION="${ROSBRIDGE_DIRECCION:-127.0.0.1}"
IMAGEN="coche-robot-ros2:jazzy"

# ---------- ¿El puerto está libre? (p. ej. un rosbridge que se quedó colgado de otra vez) ----------
if [ ! -f /.dockerenv ] && ss -ltnH "sport = :$PUERTO" 2> /dev/null | grep -q .; then
  OCUPA=$(ss -ltnpH "sport = :$PUERTO" 2> /dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  QUE=""; PADRE=""
  if [ -n "$OCUPA" ]; then
    QUE=$(ps -o args= -p "$OCUPA" | cut -c1-70)
    PADRE=$(ps -o comm= -p "$(ps -o ppid= -p "$OCUPA" | tr -d ' ')" 2> /dev/null || true)
  fi
  if [[ "$QUE" == *rosbridge* && "$PADRE" == ros2 ]] || docker ps -q -f name='^coche-robot-ros2$' 2> /dev/null | grep -q .; then
    # Su "ros2 launch" sigue vivo: es otro conectar.sh en marcha, no uno colgado. No se toca.
    echo "Ya está en marcha en otra terminal (rosbridge en ws://127.0.0.1:$PUERTO): no hace falta arrancarlo otra vez."
    if [ -n "$OCUPA" ]; then echo "Para reiniciarlo, ciérralo allí con Ctrl+C y vuelve a lanzarlo."
    else echo "Para reiniciarlo: docker stop coche-robot-ros2 y vuelve a lanzarlo."; fi
    exit 0
  fi
  echo "El puerto $PUERTO ya está ocupado${OCUPA:+ por el proceso $OCUPA ($QUE)}."
  if [[ "$QUE" == *rosbridge* ]] && [ -t 0 ]; then
    read -r -p "Parece un rosbridge que se quedó abierto. ¿Lo cierro? [S/n] " r
    [[ "$r" =~ ^[nN] ]] && exit 1
    kill -KILL "$OCUPA"; sleep 1
  else
    echo "Ciérralo${OCUPA:+ (kill $OCUPA)} o usa otro puerto: ROSBRIDGE_PUERTO=9091 ./conectar.sh"
    exit 1
  fi
fi

# ---------- ¿ROS 2 en este PC? ----------
if [ "$USAR_DOCKER" = 0 ] && [ -z "$ROS_DISTRO" ]; then
  for d in /opt/ros/*/setup.bash; do
    [ -f "$d" ] || continue
    echo "Cargando $d"
    set +e; source "$d"; set -e
    break
  done
fi

if [ "$USAR_DOCKER" = 0 ] && [ -z "$ROS_DISTRO" ]; then
  if command -v docker > /dev/null; then
    echo "No hay ROS 2 en este PC: uso Docker (ROS 2 Jazzy)."
    USAR_DOCKER=1
  else
    cat <<'EOF'
No encuentro ROS 2 ni Docker. Elige una:

  A) Docker (lo más fácil, sirve en cualquier Linux):
       sudo apt install docker.io && sudo usermod -aG docker $USER
       (cierra sesión y vuelve a entrar) y repite: ./conectar.sh

  B) ROS 2 (Ubuntu 24.04 -> Jazzy): https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debs.html
       y repite: ./conectar.sh
EOF
    exit 1
  fi
fi

# ---------- Con Docker ----------
if [ "$USAR_DOCKER" = 1 ] && [ "$NAV" = 1 ]; then
  echo "--nav necesita ROS 2 instalado en tu PC (la imagen de Docker no lleva Nav2)."
  exit 1
fi
if [ "$USAR_DOCKER" = 1 ]; then
  if ! docker info > /dev/null 2>&1; then
    echo "Docker está instalado pero no puedo usarlo. Prueba:"
    echo "  sudo usermod -aG docker \$USER   (y vuelve a entrar en la sesión)   o   sudo ./conectar.sh --docker"
    exit 1
  fi
  if ! docker image inspect "$IMAGEN" > /dev/null 2>&1 || [ Dockerfile -nt .imagen_creada ]; then
    echo "Creando la imagen de Docker (solo la primera vez, unos minutos; ocupa ~3,6 GB)…"
    docker build -t "$IMAGEN" .
    touch .imagen_creada
  fi
  ARGS=()
  [ -n "$PILOTO" ] && ARGS+=("$PILOTO")
  [ "$SLAM" = 1 ] && ARGS+=(--slam)
  # RViz es una ventana: el contenedor la dibuja en tu pantalla (X11; en Wayland, a través de XWayland)
  VENTANA=()
  if [ "$RVIZ" = 1 ]; then
    if [ -z "$DISPLAY" ] || ! command -v xauth > /dev/null; then
      echo "Para ver RViz desde Docker hace falta una sesión gráfica (DISPLAY) y xauth (sudo apt install xauth)."
      exit 1
    fi
    XAUTH_DOCKER=$(mktemp)
    xauth nlist "$DISPLAY" | sed -e 's/^..../ffff/' | xauth -f "$XAUTH_DOCKER" nmerge - 2> /dev/null
    chmod 644 "$XAUTH_DOCKER"
    VENTANA=(-e DISPLAY -e XAUTHORITY=/tmp/.docker.xauth -e QT_X11_NO_MITSHM=1 -e LIBGL_ALWAYS_SOFTWARE=1
             -v /tmp/.X11-unix:/tmp/.X11-unix:ro -v "$XAUTH_DOCKER:/tmp/.docker.xauth:ro")
    ARGS+=(--rviz)
  fi
  echo "rosbridge en ws://127.0.0.1:$PUERTO  (Ctrl+C para salir)"
  # La carpeta se monta en el contenedor: si cambias el piloto, basta con volver a lanzar.
  TTY=(); [ -t 0 ] && TTY=(-it)
  docker run --rm "${TTY[@]}" --init --name coche-robot-ros2 -p "127.0.0.1:$PUERTO:$PUERTO" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}" -e ROSBRIDGE_DIRECCION=0.0.0.0 -e ROSBRIDGE_PUERTO="$PUERTO" \
    "${VENTANA[@]}" -v "$PWD:/coche" -w /coche "$IMAGEN" ./conectar.sh "${ARGS[@]}" || true
  [ -n "${XAUTH_DOCKER:-}" ] && rm -f "$XAUTH_DOCKER"
  exit 0
fi

# ---------- Con ROS 2 en este PC: comprobar paquetes ----------
FALTAN=()
ros2 pkg prefix rosbridge_server > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-rosbridge-suite")
ros2 pkg prefix robot_state_publisher > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-robot-state-publisher")
ros2 pkg prefix image_transport > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-image-transport")
ros2 pkg prefix compressed_image_transport > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-image-transport-plugins")
python3 -c 'import numpy' 2> /dev/null || FALTAN+=(python3-numpy)
[ "$SLAM" = 1 ] && { ros2 pkg prefix slam_toolbox > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-slam-toolbox"); }
[ "$RVIZ" = 1 ] && { ros2 pkg prefix rviz2 > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-rviz2"); }
if [ "$NAV" = 1 ]; then
  ros2 pkg prefix nav2_bringup > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-navigation2" "ros-$ROS_DISTRO-nav2-bringup")
  python3 -c 'import yaml' 2> /dev/null || FALTAN+=(python3-yaml)
fi
if [ ${#FALTAN[@]} -gt 0 ]; then
  echo "Faltan paquetes: ${FALTAN[*]}"
  echo "  sudo apt install ${FALTAN[*]}"
  if [ -t 0 ]; then
    read -r -p "¿Los instalo ahora? [s/N] " r
    if [[ "$r" =~ ^[sS] ]]; then sudo apt-get update && sudo apt-get install -y "${FALTAN[@]}"; else exit 1; fi
  else
    exit 1
  fi
fi

# Al salir (Ctrl+C, cerrar la terminal o fallo) se cierra todo. rosbridge a veces no hace caso a Ctrl+C
# y se quedaría ocupando el puerto, así que lo que siga vivo a los 3 s se cierra a la fuerza.
cerrar() {
  trap '' INT TERM HUP                        # este script no se interrumpe mientras recoge
  trap - EXIT
  echo; echo "Cerrando…"
  kill -INT 0 2> /dev/null
  local grupo; grupo=$(ps -o pgid= $$ | tr -d ' ')
  for _ in $(seq 30); do
    # ¿queda algo de ROS? (todo lo del grupo menos este script, sus subshells y las órdenes de esta comprobación)
    [ -z "$(ps -o comm= -g "$grupo" | grep -vxE 'conectar.sh|bash|ps|grep|sleep|seq')" ] && break
    sleep 0.1
  done
  rm -f "$PARAMS_URDF" "${PARAMS_NAV:-}" "${ARBOL_NAV:-}"
  kill -KILL 0 2> /dev/null
}
trap cerrar EXIT INT TERM HUP

echo "ROS 2 $ROS_DISTRO  ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}  piloto: ${PILOTO:-ninguno (lanza tu nodo en otra terminal)}"
ros2 launch rosbridge_server rosbridge_websocket_launch.xml address:="$DIRECCION" port:="$PUERTO" &
# El modelo del coche para RViz: el URDF va en un archivo de parámetros (en la línea de órdenes no cabe)
PARAMS_URDF=$(mktemp --suffix=.yaml)
python3 -c 'import json; print("robot_state_publisher:\n  ros__parameters:\n    use_sim_time: true\n    robot_description: " + json.dumps(open("rviz/coche.urdf").read()))' > "$PARAMS_URDF"
ros2 run robot_state_publisher robot_state_publisher --ros-args --params-file "$PARAMS_URDF" > /dev/null &
# La cámara llega en JPEG desde el navegador; se republica sin comprimir en /camara/image_raw
ros2 run image_transport republish --ros-args -p in_transport:=compressed -p out_transport:=raw \
  -r in/compressed:=/camara/image_raw/compressed -r out:=/camara/image_raw &
if [ "$SLAM" = 1 ]; then
  # slam_toolbox necesita el LiDAR de -pi a pi: scan_slam.py lo republica en /scan_slam
  python3 slam/scan_slam.py &
  ros2 launch slam_toolbox online_async_launch.py use_sim_time:=true slam_params_file:="$PWD/slam/slam.yaml" &
fi
if [ "$NAV" = 1 ]; then
  # Nav2: la configuración de tu distro + lo que cambia para este coche (nav/coche.yaml)
  NAV2=$(ros2 pkg prefix nav2_bringup)/share/nav2_bringup
  PARAMS_NAV=$(mktemp --suffix=.yaml); ARBOL_NAV=$(mktemp --suffix=.xml)
  python3 nav/combinar.py "$NAV2/params/nav2_params.yaml" nav/coche.yaml "$PARAMS_NAV" \
    "$(ros2 pkg prefix nav2_bt_navigator)/share/nav2_bt_navigator/behavior_trees/navigate_to_pose_w_replanning_and_recovery.xml" "$ARBOL_NAV"
  ros2 launch nav2_bringup bringup_launch.py map:="$PWD/nav/mapa.yaml" params_file:="$PARAMS_NAV" \
    use_sim_time:=True autostart:=True > nav2.log 2>&1 &
  python3 nav/recolocar.py &             # al reiniciar la simulación, el coche vuelve a la salida también para AMCL
fi
if [ "$RVIZ" = 1 ]; then
  VISTA=rviz/coche.rviz; [ "$SLAM" = 1 ] && VISTA=rviz/coche_mapa.rviz
  [ "$NAV" = 1 ] && VISTA="$NAV2/rviz/nav2_default_view.rviz"
  rviz2 -d "$VISTA" --ros-args -p use_sim_time:=true > /dev/null 2>&1 &
fi
sleep 2
# Colores y negrita solo si la salida es una terminal (en un archivo de registro, texto normal)
if [ -t 1 ]; then B=$'\e[1m'; OK=$'\e[1;32m'; T=$'\e[1;33m'; CMD=$'\e[36m'; GR=$'\e[2m'; R=$'\e[0m'
else B=; OK=; T=; CMD=; GR=; R=; fi
# Cómo se lanza algo de ROS en otra terminal: en tu PC, con source; en Docker, dentro del contenedor
if [ -f /.dockerenv ]; then
  EN="docker exec -it coche-robot-ros2 bash -c 'source /opt/ros/jazzy/setup.bash && cd /coche && "; FIN="'"
else
  EN="source /opt/ros/$ROS_DISTRO/setup.bash && "; FIN=""
fi
cat <<EOF

${OK}✔ Listo.${R} En la web del simulador: ${B}Esc → ROS 2${R}   ${GR}(rosbridge en ws://127.0.0.1:$PUERTO)${R}
  ${GR}Nadie conduce todavía: el coche espera órdenes en /cmd_vel.${R}

${T}▸ Conducir con el teclado${R} ${GR}(modo Tiempo real, el de por defecto)${R}, en otra terminal:
    ${CMD}${EN}ros2 run teleop_twist_keyboard teleop_twist_keyboard${FIN}${R}
${T}▸ Tu nodo${R}, en otra terminal:
    ${CMD}${EN}python3 piloto_ros2.py${FIN}${R}
  ${GR}En modo Síncrono (Esc → Sincronía en ROS 2, como el reto) publica UNA orden por cada /scan.${R}
${T}▸ Volver a la salida:${R}
    ${CMD}${EN}ros2 service call /reiniciar_simulacion std_srvs/srv/Trigger${FIN}${R}
EOF
[ "$SLAM" = 1 ] && cat <<EOF
${T}▸ Mapa${R} ${GR}(slam_toolbox, topic /map)${R}. Guardarlo:
    ${CMD}${EN}ros2 service call /slam_toolbox/save_map slam_toolbox/srv/SaveMap "{name: {data: mapa}}"${FIN}${R}
EOF
if [ "$NAV" = 1 ]; then
  cat <<EOF
${T}▸ Navegación (Nav2)${R} ${GR}con el mapa nav/mapa.yaml; registro en nav2.log${R}
    El coche empieza localizado en la salida. Destino: en RViz, ${B}2D Goal Pose${R}; o en otra terminal:
    ${CMD}${EN}ros2 action send_goal /navigate_to_pose nav2_msgs/action/NavigateToPose "{pose: {header: {frame_id: map}, pose: {position: {x: 3.0, y: 0.0}, orientation: {w: 1.0}}}}"${FIN}${R}
    ${GR}Al reiniciar la vuelta o recargar la web se recoloca solo en la salida. Si se pierde: 2D Pose Estimate en RViz.${R}
EOF
fi
if [ "$RVIZ" = 1 ]; then
  echo "${T}▸ RViz${R} abierto ${GR}($VISTA)${R}"
elif [ ! -f /.dockerenv ]; then
  echo "${T}▸ RViz:${R} ${CMD}./conectar.sh --rviz${R} ${GR}(con --slam, también el mapa)${R}"
fi
echo
echo "${GR}Ctrl+C cierra todo.${R}"
[ -n "$PILOTO" ] && python3 "$PILOTO" &
wait

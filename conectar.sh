#!/bin/bash
# Conecta el simulador web del coche robot (modo ROS 2) con ROS 2 de verdad.
#
#   ./conectar.sh                    rosbridge + cámara + modelo para RViz + piloto_ros2.py
#   ./conectar.sh mi_piloto.py       con tu piloto
#   ./conectar.sh --sin-piloto       solo el puente (lanzas tu nodo aparte)
#   ./conectar.sh --docker           todo dentro de Docker (no hace falta tener ROS 2)
#   ROS_DOMAIN_ID=43 ./conectar.sh   separado de otras cosas de ROS que tengas abiertas
#
# Si tienes ROS 2 instalado (/opt/ros/<distro>) lo usa; si no, y tienes Docker, usa Docker.
# Luego, en la web: Esc -> ROS 2. Ctrl+C lo cierra todo.

set -e
cd "$(dirname "$0")"

USAR_DOCKER=0
PILOTO=piloto_ros2.py
for a in "$@"; do
  case "$a" in
    --docker) USAR_DOCKER=1 ;;
    --sin-piloto) PILOTO="" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) PILOTO="$a" ;;
  esac
done
[ -n "$PILOTO" ] && [ ! -f "$PILOTO" ] && { echo "No encuentro el piloto: $PILOTO"; exit 1; }

PUERTO="${ROSBRIDGE_PUERTO:-9090}"
DIRECCION="${ROSBRIDGE_DIRECCION:-127.0.0.1}"
IMAGEN="coche-robot-ros2:jazzy"

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
if [ "$USAR_DOCKER" = 1 ]; then
  if ! docker info > /dev/null 2>&1; then
    echo "Docker está instalado pero no puedo usarlo. Prueba:"
    echo "  sudo usermod -aG docker \$USER   (y vuelve a entrar en la sesión)   o   sudo ./conectar.sh --docker"
    exit 1
  fi
  if ! docker image inspect "$IMAGEN" > /dev/null 2>&1 || [ Dockerfile -nt .imagen_creada ]; then
    echo "Creando la imagen de Docker (solo la primera vez, unos minutos)…"
    docker build -t "$IMAGEN" .
    touch .imagen_creada
  fi
  ARGS=()
  [ -z "$PILOTO" ] && ARGS+=(--sin-piloto) || ARGS+=("$PILOTO")
  echo "rosbridge en ws://127.0.0.1:$PUERTO  (Ctrl+C para salir)"
  # La carpeta se monta en el contenedor: si cambias el piloto, basta con volver a lanzar.
  TTY=(); [ -t 0 ] && TTY=(-it)
  exec docker run --rm "${TTY[@]}" --init -p "127.0.0.1:$PUERTO:$PUERTO" \
    -e ROS_DOMAIN_ID="${ROS_DOMAIN_ID:-0}" -e ROSBRIDGE_DIRECCION=0.0.0.0 -e ROSBRIDGE_PUERTO="$PUERTO" \
    -v "$PWD:/coche" -w /coche "$IMAGEN" ./conectar.sh "${ARGS[@]}"
fi

# ---------- Con ROS 2 en este PC: comprobar paquetes ----------
FALTAN=()
ros2 pkg prefix rosbridge_server > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-rosbridge-suite")
ros2 pkg prefix robot_state_publisher > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-robot-state-publisher")
ros2 pkg prefix image_transport > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-image-transport")
ros2 pkg prefix compressed_image_transport > /dev/null 2>&1 || FALTAN+=("ros-$ROS_DISTRO-image-transport-plugins")
python3 -c 'import numpy' 2> /dev/null || FALTAN+=(python3-numpy)
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

trap 'trap - EXIT; kill 0' EXIT INT TERM      # al salir se cierra todo

echo "ROS 2 $ROS_DISTRO  ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}  piloto: ${PILOTO:-ninguno}"
ros2 launch rosbridge_server rosbridge_websocket_launch.xml address:="$DIRECCION" port:="$PUERTO" &
# El modelo del coche para RViz: el URDF va en un archivo de parámetros (en la línea de órdenes no cabe)
PARAMS_URDF=$(mktemp --suffix=.yaml)
python3 -c 'import json; print("robot_state_publisher:\n  ros__parameters:\n    use_sim_time: true\n    robot_description: " + json.dumps(open("rviz/coche.urdf").read()))' > "$PARAMS_URDF"
ros2 run robot_state_publisher robot_state_publisher --ros-args --params-file "$PARAMS_URDF" > /dev/null &
# La cámara llega en JPEG desde el navegador; se republica sin comprimir en /camara/image_raw
ros2 run image_transport republish --ros-args -p in_transport:=compressed -p out_transport:=raw \
  -r in/compressed:=/camara/image_raw/compressed -r out:=/camara/image_raw &
sleep 2
cat <<EOF

  Listo. En la web del simulador: Esc -> ROS 2  (rosbridge: ws://127.0.0.1:$PUERTO)
  RViz:      rviz2 -d rviz/coche.rviz --ros-args -p use_sim_time:=true
  Reiniciar: ros2 service call /reiniciar_simulacion std_srvs/srv/Trigger

EOF
[ -n "$PILOTO" ] && python3 "$PILOTO" &
wait

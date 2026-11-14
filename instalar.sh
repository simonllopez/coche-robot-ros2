#!/bin/bash
# Descarga lo necesario para el modo ROS 2 del simulador web en ~/coche-robot-ros2 y lo arranca.
#
#   wget -qO- https://raw.githubusercontent.com/simonllopez/coche-robot-ros2/main/instalar.sh | bash
#
# Otra carpeta: ... | DESTINO=~/otra bash      Solo descargar: ... | NO_ARRANCAR=1 bash

set -e
REPO="https://github.com/simonllopez/coche-robot-ros2/archive/refs/heads/main.tar.gz"
DESTINO="${DESTINO:-$HOME/coche-robot-ros2}"

mkdir -p "$DESTINO"
echo "Descargando en $DESTINO…"
if command -v wget > /dev/null; then wget -qO- "$REPO"; else curl -fsSL "$REPO"; fi \
  | tar xz -C "$DESTINO" --strip-components=1
chmod +x "$DESTINO"/*.sh

echo "Hecho. Para arrancarlo cuando quieras:  cd $DESTINO && ./conectar.sh"
[ -n "$NO_ARRANCAR" ] && exit 0
cd "$DESTINO"
exec ./conectar.sh < /dev/tty      # el teclado de la terminal (para Ctrl+C y las preguntas)

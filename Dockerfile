# ROS 2 Jazzy con todo lo que necesita el modo ROS 2 de la web del simulador (rosbridge, cámara,
# teleop, slam_toolbox y RViz). No hace falta construirla a mano: ./conectar.sh lo hace la primera vez.
FROM ros:jazzy-ros-base

RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-jazzy-rosbridge-suite ros-jazzy-robot-state-publisher \
        ros-jazzy-image-transport ros-jazzy-image-transport-plugins ros-jazzy-teleop-twist-keyboard \
        ros-jazzy-slam-toolbox ros-jazzy-rviz2 ros-jazzy-rviz-default-plugins python3-numpy \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /coche
COPY . /coche
CMD ["./conectar.sh"]

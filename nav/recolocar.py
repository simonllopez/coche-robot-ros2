"""
Vuelve a colocar el coche en la salida (/initialpose para AMCL) cada vez que la simulación empieza de cero:
al conectar la web, al recargarla o al reiniciar la vuelta. Se nota porque la odometría salta de golpe
(vuelve a 0). Una pausa en la web no cuenta: la odometría sigue donde estaba.

Sin esto, AMCL seguiría creyendo que el coche está donde lo dejó y Nav2 planearía desde ahí.
La salida es el origen del marco "map" en nav/mapa.yaml.
"""
import math

import rclpy
from geometry_msgs.msg import PoseWithCovarianceStamped
from nav_msgs.msg import Odometry
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node

SALTO = 0.3          # m entre dos /odom seguidos (50 ms): eso no es moverse, es un reinicio
ESPERA = 20          # mensajes de /odom (~1 s) antes de colocarlo: que TF tenga ya datos nuevos


class Recolocar(Node):
    def __init__(self):
        super().__init__("recolocar")
        self.pub = self.create_publisher(PoseWithCovarianceStamped, "initialpose", 10)
        self.create_subscription(Odometry, "odom", self.al_odom, 10)
        self.anterior = None
        self.pendiente = 0

    def al_odom(self, m):
        p = m.pose.pose.position
        if self.anterior is None or math.hypot(p.x - self.anterior[0], p.y - self.anterior[1]) > SALTO:
            self.pendiente = ESPERA
        self.anterior = (p.x, p.y)
        if self.pendiente:
            self.pendiente -= 1
            if not self.pendiente:
                self.colocar()

    def colocar(self):
        p = PoseWithCovarianceStamped()
        p.header.frame_id = "map"           # sin marca de tiempo: AMCL usa la transformada más reciente
        p.pose.pose.orientation.w = 1.0
        p.pose.covariance[0] = p.pose.covariance[7] = 0.01      # x, y: ±10 cm
        p.pose.covariance[35] = 0.01                            # giro: ±0,1 rad
        self.pub.publish(p)
        self.get_logger().info("Simulación desde la salida: coche colocado en el origen del mapa")


def main():
    rclpy.init()
    try:
        rclpy.spin(Recolocar())
    except (KeyboardInterrupt, ExternalShutdownException):
        pass


if __name__ == "__main__":
    main()

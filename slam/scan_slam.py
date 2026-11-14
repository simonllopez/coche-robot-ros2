"""
Repite /scan en /scan_slam con los ángulos de -pi a pi (mismos rayos, reordenados).
slam_toolbox (Karto) se lía con los scans de 0 a 2·pi que publica el simulador.
"""
import math

import rclpy
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import LaserScan


class Reordenar(Node):
    def __init__(self):
        super().__init__("scan_slam")
        q = QoSProfile(depth=50, reliability=ReliabilityPolicy.RELIABLE)
        self.pub = self.create_publisher(LaserScan, "scan_slam", q)
        self.create_subscription(LaserScan, "scan", self.al_recibir, q)

    def al_recibir(self, s):
        n = len(s.ranges)
        mitad = n // 2                                   # el rayo n/2 está a pi: pasa a ser el primero
        s.ranges = list(s.ranges[mitad:]) + list(s.ranges[:mitad])
        if s.intensities:
            s.intensities = list(s.intensities[mitad:]) + list(s.intensities[:mitad])
        s.angle_min = s.angle_min + mitad * s.angle_increment - 2 * math.pi
        s.angle_max = s.angle_min + (n - 1) * s.angle_increment
        self.pub.publish(s)


def main():
    rclpy.init()
    try:
        rclpy.spin(Reordenar())
    except (KeyboardInterrupt, ExternalShutdownException):
        pass                                             # Ctrl+C: cerrar sin traza


if __name__ == "__main__":
    main()

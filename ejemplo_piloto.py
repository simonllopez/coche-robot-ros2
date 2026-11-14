"""
Piloto de ejemplo para el reto: "sigue el hueco" con el LiDAR.

Es la plantilla para los participantes. Reglas del reto:
  - Escucha /scan (y si quieres /odom y /camara/image_raw).
  - Publica UNA orden en /cmd_vel por cada /scan que recibas, dentro de su callback.
  - Nada de relojes del ordenador ni aleatoriedad sin semilla: el resultado debe depender
    solo de los sensores, para que sea igual en cualquier PC.

Los ajustes son parámetros de ROS 2: en la web salen como deslizadores y casillas, y en ROS
se cambian con  ros2 param set /piloto_ejemplo vel_max 1.5

    source /opt/ros/<tu_distro>/setup.bash
    python3 ejemplo_piloto.py
"""

import math

import numpy as np
import rclpy
from geometry_msgs.msg import Twist
from rcl_interfaces.msg import FloatingPointRange, IntegerRange, ParameterDescriptor
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import LaserScan

BATALLA = 0.26          # m (distancia entre ejes del coche)
GIRO_MAX = 0.5          # rad

# Parámetros: nombre -> (valor, mínimo, máximo, explicación).
# El tipo sale del valor: float (1.0) = deslizador, int (6) = deslizador de enteros, bool (True) = casilla.
PARAMETROS = {
    "vel_max": (1.0, 0.3, 5.0, "m/s máximos (subirla es lo primero que querrás probar)"),
    "campo": (100.0, 30.0, 180.0, "grados: mira hacia delante ±campo"),
    "ventana": (6, 1, 20, "rayos a cada lado para medir el hueco"),
    "cerca": (0.4, 0.1, 1.0, "m: si la barrera está más cerca por un lado, apartarse"),
    "frenar_en_curvas": (True, None, None, "ir más despacio cuanto más gira"),
}


class Piloto(Node):
    def __init__(self):
        super().__init__("piloto_ejemplo")
        for nombre, (valor, minimo, maximo, texto) in PARAMETROS.items():
            d = ParameterDescriptor(description=texto)
            if isinstance(valor, float):
                d.floating_point_range = [FloatingPointRange(from_value=minimo, to_value=maximo, step=0.0)]
            elif isinstance(valor, int) and not isinstance(valor, bool):
                d.integer_range = [IntegerRange(from_value=minimo, to_value=maximo, step=1)]
            self.declare_parameter(nombre, valor, d)
        fiable = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE)
        self.pub = self.create_publisher(Twist, "cmd_vel", fiable)
        self.create_subscription(LaserScan, "scan", self.al_recibir_scan, fiable)
        self.get_logger().info(f"Listo: vel_max={self.p('vel_max')} m/s, esperando /scan")

    def p(self, nombre):
        return self.get_parameter(nombre).value

    def al_recibir_scan(self, scan):
        campo, ventana, cerca, vel_max = math.radians(self.p("campo")), self.p("ventana"), self.p("cerca"), self.p("vel_max")

        r = np.array(scan.ranges, dtype=float)
        r[~np.isfinite(r)] = scan.range_max
        angulos = scan.angle_min + np.arange(len(r)) * scan.angle_increment
        angulos = (angulos + math.pi) % (2 * math.pi) - math.pi        # de -pi a pi (0 = delante)

        delante = np.abs(angulos) <= campo
        a, d = angulos[delante], r[delante]
        orden = np.argsort(a)
        a, d = a[orden], d[orden]
        # "hueco": para cada dirección, lo más cerca que hay a ±ventana rayos (así no apunta a un agujero estrecho)
        hueco = np.array([d[max(0, i - ventana):i + ventana + 1].min() for i in range(len(d))])
        objetivo = a[np.argmax(hueco - 0.2 * np.abs(a))]                # preferir ir recto si da igual

        # apartarse de la barrera si está muy cerca por un lado
        izq = r[(angulos > math.radians(30)) & (angulos < math.radians(110))].min()
        der = r[(angulos < -math.radians(30)) & (angulos > -math.radians(110))].min()
        if min(izq, der) < cerca:
            objetivo += 1.0 * (izq - der)

        giro = float(np.clip(2.0 * objetivo, -GIRO_MAX, GIRO_MAX))
        frente = float(d[np.abs(a) < math.radians(10)].min())
        v = float(np.clip(0.35 + 0.45 * frente, 0.35, vel_max))
        if self.p("frenar_en_curvas"):
            v *= 1.0 - 0.6 * abs(giro) / GIRO_MAX                        # más despacio en las curvas

        t = Twist()
        t.linear.x = v
        t.angular.z = v * math.tan(giro) / BATALLA                       # dirección -> velocidad de giro
        self.pub.publish(t)


def main():
    rclpy.init()
    nodo = Piloto()
    try:
        rclpy.spin(nodo)
    except KeyboardInterrupt:
        pass
    nodo.destroy_node()
    if rclpy.ok():
        rclpy.shutdown()


if __name__ == "__main__":
    main()

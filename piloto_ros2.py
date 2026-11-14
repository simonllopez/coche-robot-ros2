"""
Piloto para ROS 2, algo mejor que ejemplo_piloto.py. Todo en un único archivo.

Idea (la del "extensor de discontinuidades", muy usada en F1TENTH):
  1. Del LiDAR, solo lo que hay delante (±campo).
  2. Donde hay un salto brusco de distancia (el borde de una barrera), se "ensancha" la
     barrera lo que mide medio coche más un margen: así no apunta a huecos por los que no cabe.
  3. Apunta hacia el rayo más lejano que queda (si hay empate, el más recto).
  4. Velocidad, la menor de tres:
       - la máxima del parámetro vel_max,
       - la que permite la curva sin derrapar  (v² · tan(giro) / batalla <= acel_lateral),
       - la que permite frenar antes de lo que hay delante (v² <= 2 · frenada · distancia libre).
  5. Si se queda atascado contra una barrera (pide ir y la odometría dice que no se mueve),
     da marcha atrás un momento girando al revés.

Reglas del reto: una orden en /cmd_vel por cada /scan, nada de relojes del ordenador ni azar
sin semilla. Todo depende solo de los sensores, así que el resultado es igual en cualquier PC.

    source /opt/ros/<tu_distro>/setup.bash
    python3 piloto_ros2.py
    ros2 param set /piloto_ros2 vel_max 3.0        (se puede cambiar en marcha)
"""

import math

import numpy as np
import rclpy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from rcl_interfaces.msg import FloatingPointRange, IntegerRange, ParameterDescriptor
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy
from sensor_msgs.msg import LaserScan

BATALLA = 0.26          # m: distancia entre ejes
ANCHO_COCHE = 0.23      # m: de rueda a rueda, por fuera
GIRO_MAX = 0.5          # rad: lo que gira la dirección como mucho
PASO = 0.05             # s entre /scan (20 Hz)

# Parámetros de ROS 2: nombre -> (valor, mínimo, máximo, explicación)
PARAMETROS = {
    "vel_max": (5.0, 0.5, 5.0, "m/s en recta"),
    "acel_lateral": (7.0, 1.0, 10.0, "m/s² en curva: más alto = entra más rápido (el agarre da ~9)"),
    "frenada": (6.0, 1.0, 10.0, "m/s² de frenada que da por buena para pararse antes de un obstáculo"),
    "margen": (0.12, 0.0, 0.4, "m de más a cada lado al ensanchar las barreras"),
    "campo": (90.0, 45.0, 135.0, "grados: mira hacia delante ±campo"),
    "salto": (0.25, 0.05, 1.0, "m: diferencia entre rayos vecinos que cuenta como borde de barrera"),
    "ganancia_giro": (1.0, 0.3, 2.0, "multiplica el giro hacia el hueco"),
    "distancia_segura": (0.25, 0.05, 0.8, "m que quiere dejar libres delante al frenar"),
    "rescate": (True, None, None, "marcha atrás si se queda atascado"),
}


class Piloto(Node):
    def __init__(self):
        super().__init__("piloto_ros2")
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
        self.create_subscription(Odometry, "odom", self.al_recibir_odom, fiable)

        self.v_odom = 0.0           # velocidad medida (odometría)
        self.v_pedida = 0.0
        self.giro = 0.0
        self.atascado = 0           # scans seguidos pidiendo ir y sin moverse
        self.marcha_atras = 0       # scans que quedan de maniobra de rescate
        self.giro_rescate = 0.0
        self.get_logger().info(f"Listo: vel_max={self.p('vel_max')} m/s, acel_lateral={self.p('acel_lateral')} m/s²")

    def p(self, nombre):
        return self.get_parameter(nombre).value

    def al_recibir_odom(self, msg):
        self.v_odom = msg.twist.twist.linear.x

    # ---------- Cada /scan: una orden ----------
    def al_recibir_scan(self, scan):
        v, giro = self.decidir(scan)
        self.v_pedida, self.giro = v, giro
        t = Twist()
        t.linear.x = v
        t.angular.z = v * math.tan(giro) / BATALLA                       # dirección -> velocidad de giro
        self.pub.publish(t)

    def decidir(self, scan):
        # Maniobra de rescate en curso
        if self.marcha_atras > 0:
            self.marcha_atras -= 1
            return -0.6, self.giro_rescate

        r = np.array(scan.ranges, dtype=float)
        r[~np.isfinite(r)] = scan.range_max
        r = np.clip(r, scan.range_min, scan.range_max)
        angulos = scan.angle_min + np.arange(len(r)) * scan.angle_increment
        angulos = (angulos + math.pi) % (2 * math.pi) - math.pi          # de -pi a pi (0 = delante)
        orden = np.argsort(angulos)
        angulos, r = angulos[orden], r[orden]
        inc = scan.angle_increment

        delante = np.abs(angulos) <= math.radians(self.p("campo"))
        a, d = angulos[delante], r[delante].copy()

        # 2. Extensor de discontinuidades: en cada salto, la parte cercana "tapa" medio coche + margen
        mitad = ANCHO_COCHE / 2 + self.p("margen")
        original = d.copy()
        for i in range(len(d) - 1):
            cerca, lejos = sorted((original[i], original[i + 1]))
            if lejos - cerca < self.p("salto"):
                continue
            n = int(math.ceil(math.atan2(mitad, max(cerca, 0.05)) / inc))
            if original[i] < original[i + 1]:          # barrera a la izquierda del salto: ensanchar hacia i+1...
                tramo = slice(i + 1, min(len(d), i + 1 + n))
            else:                                      # ...o hacia i, ..., i-n
                tramo = slice(max(0, i + 1 - n), i + 1)
            d[tramo] = np.minimum(d[tramo], cerca)

        # 3. El rayo más lejano (a igualdad, el más recto)
        objetivo = a[np.argmax(d - 0.15 * np.abs(a))]

        # Giro tipo "seguimiento puro": apuntar a un punto a la distancia libre en esa dirección
        mira = max(0.5, min(float(d[np.argmax(d - 0.15 * np.abs(a))]), 2.0))
        giro = math.atan2(2 * BATALLA * math.sin(objetivo), mira) * self.p("ganancia_giro")

        # Apartarse si una barrera queda muy pegada por un lado (entre 60° y 120°)
        lado_izq = r[(angulos > math.radians(60)) & (angulos < math.radians(120))].min()
        lado_der = r[(angulos < -math.radians(60)) & (angulos > -math.radians(120))].min()
        if min(lado_izq, lado_der) < mitad + 0.05:
            giro += 0.6 * (lado_izq - lado_der)
        giro = float(np.clip(giro, -GIRO_MAX, GIRO_MAX))

        # 4. Velocidad: la menor de las tres
        frente = float(original[np.abs(a) < math.radians(8)].min())
        v_curva = math.sqrt(self.p("acel_lateral") * BATALLA / max(math.tan(abs(giro)), 1e-3))
        libre = max(frente - self.p("distancia_segura"), 0.0)
        v_frenar = math.sqrt(2 * self.p("frenada") * libre)
        v = max(0.4, min(self.p("vel_max"), v_curva, v_frenar))

        # 5. ¿Atascado? (pedía ir hacia delante y la odometría dice que casi no se mueve)
        if self.p("rescate"):
            if self.v_pedida > 0.3 and abs(self.v_odom) < 0.05:
                self.atascado += 1
            else:
                self.atascado = 0
            if self.atascado >= 15:                      # 0,75 s
                self.atascado = 0
                self.marcha_atras = 12                   # 0,6 s hacia atrás
                self.giro_rescate = -math.copysign(GIRO_MAX, giro if abs(giro) > 0.05 else (lado_izq - lado_der))
                self.get_logger().warning("Atascado: marcha atrás")
                return -0.6, self.giro_rescate

        return v, giro


def main():
    rclpy.init()
    nodo = Piloto()
    try:
        rclpy.spin(nodo)
    except (KeyboardInterrupt, ExternalShutdownException):     # Ctrl+C o cierre desde fuera
        pass
    nodo.destroy_node()
    if rclpy.ok():
        rclpy.shutdown()


if __name__ == "__main__":
    main()

"""
Junta la configuración de Nav2 de tu distro con nav/coche.yaml (lo que cambia para este coche).

    python3 nav/combinar.py <nav2_params.yaml de la distro> nav/coche.yaml <salida.yaml> [<árbol.xml de la distro> <árbol de salida.xml>]

Los diccionarios se mezclan por claves; los plugins enteros (FollowPath, GridBased) se sustituyen,
para no arrastrar parámetros del controlador o el planificador por defecto.

Con el árbol de comportamiento: se copia el de la distro sin la recuperación "Spin" (girar sobre sí mismo),
que un coche no puede hacer (perdería 10 s intentándolo), y se le dice a bt_navigator que use la copia.
"""
import re
import sys

import yaml

SUSTITUIR = {"FollowPath", "GridBased"}


def mezclar(base, cambios):
    for clave, valor in cambios.items():
        if clave in SUSTITUIR or not isinstance(valor, dict) or not isinstance(base.get(clave), dict):
            base[clave] = valor
        else:
            mezclar(base[clave], valor)
    return base


def main():
    distro, coche, salida = sys.argv[1:4]
    with open(distro) as f:
        base = yaml.safe_load(f)
    with open(coche) as f:
        cambios = yaml.safe_load(f)
    if len(sys.argv) >= 6:
        arbol_distro, arbol_salida = sys.argv[4:6]
        with open(arbol_distro) as f:
            arbol = re.sub(r"\s*<Spin\b[^>]*/>", "", f.read())
        with open(arbol_salida, "w") as f:
            f.write(arbol)
        cambios.setdefault("bt_navigator", {}).setdefault("ros__parameters", {})["default_nav_to_pose_bt_xml"] = arbol_salida
    with open(salida, "w") as f:
        yaml.safe_dump(mezclar(base, cambios), f, sort_keys=False, allow_unicode=True)


if __name__ == "__main__":
    main()

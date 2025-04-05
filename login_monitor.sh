#!/bin/bash
# ------------------------------------------------------------------------------
# Monitor de conexiones SSH basado en /var/log/auth.log.
# Registra:
#   - Inicios de sesión (líneas con "Accepted")
#   - Cierre de sesión (líneas con "session closed for user")
# Calcula la duración de la sesión y escribe un registro formateado.
#
# Los registros se guardan en un archivo mensual, con nombre:
#   loginlog_MM-YYYY.log
# Dentro del archivo se agrega una cabecera diaria (Día dd-mm-YYYY).
#
# Se requiere ejecutarlo como root o con permisos para leer /var/log/auth.log.
# La zona horaria se configura a Europa (ej. Europe/Madrid).
# ------------------------------------------------------------------------------
 
# Directorio donde se encuentra el script (y donde se guardarán los logs)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
 
# Inicializamos el identificador del mes (MM-YYYY) y definimos el archivo de salida
CURRENT_MONTH=$(date +"%m-%Y")
OUTPUT_FILE="${SCRIPT_DIR}/loginlog_${CURRENT_MONTH}.log"
 
# Variable para almacenar la última fecha con cabecera agregada (para cabecera diaria)
LAST_DATE=""
 
# Configuramos la zona horaria europea (modifica si es necesario)
export TZ="Europe/Madrid"
 
# Declaramos array asociativo para almacenar información de sesiones activas (clave=PID)
declare -A SESSIONS
 
# Función para convertir el timestamp del log (por ejemplo, "Apr  4 10:06:54") a epoch
# Se asume el año actual
to_epoch() {
    local date_str="$1"
    local year
    year=$(date +%Y)
    date -d "$date_str $year" +%s 2>/dev/null
}
 
# Función para formatear duración (en segundos) a "Xh:Ym:Zs"
format_duration() {
    local total_s="$1"
    local h=$((total_s / 3600))
    local m=$(((total_s % 3600) / 60))
    local s=$((total_s % 60))
    echo "${h}h:${m}m:${s}s"
}
 
# Función para actualizar el archivo de salida:
# 1. Si cambia el mes (nuevo mes), se crea un nuevo archivo.
# 2. Si es un nuevo día, añade una cabecera con "Día dd-mm-YYYY".
update_output_file() {
    local current_date new_month
    current_date=$(date +"%d-%m-%Y")
    new_month=$(date +"%m-%Y")
    if [ "$new_month" != "$CURRENT_MONTH" ]; then
        # Se ha cambiado de mes: actualizamos CURRENT_MONTH y OUTPUT_FILE
        CURRENT_MONTH="$new_month"
        OUTPUT_FILE="${SCRIPT_DIR}/loginlog_${CURRENT_MONTH}.log"
        echo "Creado nuevo archivo de log para el mes: $CURRENT_MONTH" >> "$OUTPUT_FILE"
        LAST_DATE=""
    fi
    if [ "$current_date" != "$LAST_DATE" ]; then
        echo -e "\nDía $current_date" >> "$OUTPUT_FILE"
        LAST_DATE="$current_date"
    fi
}
 
# Función para agregar un mensaje al log, actualizando la cabecera diaria si es necesario
append_log() {
    update_output_file
    echo "$1" >> "$OUTPUT_FILE"
}
 
# Manejo de salida (Ctrl+C)
cleanup() {
    echo -e "\nMonitor finalizado: $(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT_FILE"
    echo "Reporte guardado en: $OUTPUT_FILE"
    exit 0
}
trap cleanup SIGINT
 
# Ruta del log de autenticación (ajusta según tu distribución, ej. /var/log/secure en CentOS/RedHat)
AUTH_LOG="/var/log/auth.log"
 
# Escribimos cabecera de inicio en el archivo
echo "=== Iniciando monitor de auth.log: $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$OUTPUT_FILE"
 
# Seguimos el log en tiempo real con tail -F
tail -F "$AUTH_LOG" | while read -r line; do
    # Extraemos el PID del proceso sshd (por ejemplo, "sshd[12345]")
    pid=$(echo "$line" | grep -oP 'sshd\[\K[0-9]+')
    [ -z "$pid" ] && continue
 
    # Extraemos el timestamp de la línea (ejemplo: "Apr  4 10:06:54")
    timestamp_str=$(echo "$line" | awk '{print $1, $2, $3}')
    epoch_time=$(to_epoch "$timestamp_str")
    now_human=$(date '+%Y-%m-%d %H:%M:%S')
 
    # 1) Verificamos si es un inicio de sesión exitoso (línea que contiene "Accepted")
    echo "$line" | grep -q "Accepted"
    if [ $? -eq 0 ]; then
        # Ejemplo de línea:
        # "Apr  4 10:06:54 srv sshd[12345]: Accepted password for usuario from IP port 22 ssh2"
        user=$(echo "$line" | awk -F "for " '{print $2}' | awk '{print $1}')
        ip=$(echo "$line" | awk -F "from " '{print $2}' | awk '{print $1}')
 
        # Guardamos la sesión en el array: valor="epoch|usuario|IP|timestamp_linea"
        SESSIONS["$pid"]="${epoch_time}|${user}|${ip}|${timestamp_str}"
 
        msg="NUEVA CONEXION -> Usuario: $user, IP: $ip, Hora Log: $timestamp_str"
        echo "[$now_human] $msg"
        append_log "[$now_human] $msg"
    fi
 
    # 2) Verificamos si es un cierre de sesión ("session closed for user")
    echo "$line" | grep -q "session closed for user"
    if [ $? -eq 0 ]; then
        user_closed=$(echo "$line" | awk -F "for user " '{print $2}' | awk '{print $1}')
 
        if [ -n "${SESSIONS[$pid]}" ]; then
            stored="${SESSIONS[$pid]}"
            start_epoch=$(echo "$stored" | awk -F'|' '{print $1}')
            start_user=$(echo "$stored" | awk -F'|' '{print $2}')
            start_ip=$(echo "$stored" | awk -F'|' '{print $3}')
 
            # Calculamos la duración de la sesión
            duration_s=$((epoch_time - start_epoch))
            duration_str=$(format_duration "$duration_s")
 
            msg="DESCONEXION -> Usuario: $start_user, IP: $start_ip, Hora Log: $timestamp_str, Duración: $duration_str"
            echo "[$now_human] $msg"
            append_log "[$now_human] $msg"
 
            unset SESSIONS["$pid"]
        else
            msg="DESCONEXION -> Usuario: $user_closed (SIN REGISTRO PREVIO), Hora Log: $timestamp_str"
            echo "[$now_human] $msg"
            append_log "[$now_human] $msg"
        fi
    fi
done

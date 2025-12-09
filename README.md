# Guía paso a paso para ejecución

1) Asegurarse de tener descargado en la computadora **Nodejs y Git**.

2) Descargar dependencias Lambda

   Dependencias del lambda_backend
   
        
   EN (**cd TripMate-infra/app_code/lambdas/lambda_backend**)
   
        npm ci --only=production


      Dependencias del lambda_dbinit
   
        
     EN (**cd TripMate-infra/app_code/lambdas/lambda_dbinit**)
   
        npm ci --only=production

3) Configurar AWS CLI

   En la dirección main del proyecto (**cd TripMate-infra**)

      -aws configure


        Credenciales
        Región: us-east-1
        Default output format: json

5) Ejecutar Terraform

      En la dirección main del proyecto (**cd TripMate-infra**)
       
        terraform init
        terraform apply -var-file="env/dev.tfvars"

6) Acceso a la aplicación **IMPORTANTE LEER**

Una vez desplegada la infraestructura, se debe ingresar al enlace del s3_website que aparece en la terminal después de ejecutar el terraform apply. Este enlace dirige a una página de bienvenida donde hay un botón para iniciar sesión con Cognito. Al hacer clic, se redirige al login de Cognito, y una vez iniciada la sesión, el usuario accede a la aplicación principal.

Dentro de la aplicación, el usuario puede crear viajes ingresando un nombre, presionando “Guardar”, esperando unos segundos y luego haciendo clic en “Listar viajes” para visualizarlos. Además, dentro de cada viaje se pueden crear actividades y votar.

En cuanto a la funcionalidad de unirse, otro usuario puede iniciar sesión con una cuenta diferente en Cognito y unirse a un viaje existente ingresando el código del viaje creado por otra persona. De esta manera, varios usuarios pueden estar en un mismo viaje.

Si un usuario agrega una nueva actividad o realiza un voto, los demás deben refrescar la página, presionar “Listar viajes” nuevamente y abrir el viaje para ver los cambios actualizados. SIEMPRE QUE SE REFRESCA LA PAGINA HAY QUE PRESIONAR LISTAR VIAJES PARA VOLVER A VERLOS.

FUNCIONALIDADES:

   1)Inicio de sesion con mail y contraseña seguros mediante cognito.
   
   2)Crear viajes con sus respectivas fechas de inicio y fin.

   3)Crear presupuestos por viaje.
   
   4)Invitar miembros a viajes mediante codigo de acceso.
   
   5)Crear actividades en cada viaje (nombre y fecha).
   
   6)Votacion en tiempo real de las actividades de los viajes.
   
   7)Presupuesto de actividad (se resta al presupuesto total).
   
   8)Aviso por mail cuando se llega al 70% del presupuesto del viaje.
   
   9)To-do list por viaje.
   
   10)Calculadora de pagos (que miembro debe cuanto en cada viaje).
   
   11)Aviso cuando miembro del viaje paga una actividad.
   
   12)Aviso cuando miembro del viaje vota.
   
   13)Aviso cuando faltan 24hs para pagar la actividad.
   


## Descripción de módulos

### COGNITO_AUTH

Este módulo se encarga de crear todo lo necesario para manejar usuarios con Amazon Cognito.
Básicamente, genera un User Pool donde los usuarios se registran e inician sesión usando su email como nombre de usuario.
También activa la verificación automática por correo y permite recuperar la cuenta si el usuario la pierde.
La política de contraseñas es bastante simple, y además genera un dominio único para el login, así no se choca con otros entornos.
Como salida, muestra datos importantes como el ID del User Pool y la URL del dominio para el login.

### RDS_MYSQL

Este módulo crea una base de datos MySQL en Amazon RDS, que se usa para guardar la información de la aplicación.
Primero define un subnet group dentro de la VPC para que la base quede bien ubicada en la red privada.
Después levanta una instancia de MySQL con un tamaño chico y 20GB de almacenamiento.
La base no es pública y se puede activar o no la opción Multi-AZ por si se necesita más disponibilidad.
La autenticación se hace con usuario y contraseña que vienen por variables, y el nombre de la base se genera automáticamente.
Al final, el módulo devuelve el endpoint de la base de datos, que es la dirección para conectarse desde las Lambdas.

### S3_WEBSITE

Este módulo sirve para publicar la parte web del proyecto (el frontend) usando Amazon S3.
Lo que hace es crear un bucket único con nombre dinámico, para evitar que se repita con otros proyectos.
Dentro del bucket se activa el hosting estático, configurando el archivo login.html como página principal.
Además, sube directamente los archivos HTML y JavaScript del proyecto (login y app) con el código JS inyectado por Terraform.
Finalmente, muestra como salida la URL del sitio web, para poder acceder directamente al frontend.

### SNS_TOPIC

Este módulo crea un tópico SNS para mandar notificaciones o alertas del sistema.
Se genera un nombre único con un sufijo aleatorio para evitar conflictos entre equipos o ambientes.
También permite agregar una suscripción por email, pero solo si se pasa una dirección de correo en las variables.
Si no se pone nada, no se crea y no tira error (gracias al COUNT condicional).
El módulo devuelve el ARN del topic, que se puede usar para conectarlo con las Lambdas o con otros servicios que necesiten enviar notificaciones.

### VPC_EXT

Es el modulo externo que usa TripMate.
Este módulo arma toda la infraestructura de red (VPC) del proyecto.
Usa el módulo oficial de AWS para crear las subredes públicas, privadas y de base de datos, además de configurar un NAT Gateway para que las Lambdas puedan salir a Internet sin ser accesibles desde afuera.
También crea dos grupos de seguridad (SGs):

Uno para las Lambdas, que solo permite tráfico de salida.

Otro para la base de datos, que deja entrar solo conexiones en el puerto 3306 desde las Lambdas.

Como outputs, devuelve los IDs de las subnets, los SGs y el ID de la VPC.

### LAMBDAS_API

Se encarga de todo el backend del sistema, usando AWS Lambda (para ejecutar funciones sin servidor) y API Gateway (para exponer endpoints REST).
Tiene 4 funciones Lambda:

backend: maneja las operaciones principales como guardar, listar, unirse a viajes, votar, etc.

callback: se usa cuando el usuario vuelve del login de Cognito a la app.

signout: cierra la sesión y redirige al login.

dbinit: inicializa la base de datos.

Cada Lambda se empaqueta automáticamente en ZIP y se conecta a la VPC para poder hablar con RDS.
La API Gateway expone rutas como /guardar, /listar, /unirse, /callback, /signout y /viajes/{id}/actividades, todas conectadas con las Lambdas mediante integraciones tipo proxy.
Tiene configurado CORS para que el frontend pueda hacer llamadas sin bloqueos.
Por último, también crea un User Pool Client de Cognito con OAuth 2.0, que se usa para manejar el login y logout desde el frontend.

## Explicación de funciones y meta-argumentos


### Funciones usadas

#### file()
Por ejemplo en: main.tf del módulo s3_website
Sirve para leer archivos HTML desde el disco (como el login.html) y meterlos en el bucket de S3.

content = join("", [file(var.login_file_path), "\n<script>\n", var.login_inline_js, "\n</script>\n"])


#### join()
Por ejemplo en: main.tf en s3_website
Sirve para unir contenido HTML y JavaScript en un solo string. Muy útil para inyectar el JS al final del archivo HTML.

#### coalesce()
Por ejemplo en: main.tf en lambdas_api
Sirve para usar un valor por defecto si no se pasó uno. En este caso, para el origen de CORS.

allow_origin = coalesce(var.cors_origin, "http://${local.frontend_host}")


#### replace()
Por ejemplo en: main.tf en s3_website
Se usa para reemplazar caracteres no válidos (como guiones bajos) en nombres de buckets.

#### lower()
Por ejemplo en: main.tf en cognito_auth y s3_website
Sirve para pasar strings a minúsculas, ya que algunos nombres en AWS lo exigen.

#### trimspace()
Por ejemplo en: main.tf en sns_topic
Sirve para eliminar espacios vacíos de un string antes de chequear si está vacío o no.

#### element() y compact()
Por ejemplo en: main.tf en s3_website
Sirve para elegir un nombre válido de bucket, tomando el que se pasó o el que se generó dinámicamente.

#### merge()
Por ejemplo en: main.tf de s3_website
Se usa para unir dos grupos de etiquetas en uno solo. Combina las etiquetas generales del proyecto (var.tags) con una etiqueta adicional llamada Name.

### Meta-argumentos usados

#### count
Por ejemplo en: main.tf en sns_topic, y también en creación de roles en lambdas_api.
Se usó para crear recursos solo si se cumple una condición (por ejemplo, la suscripción por email solo se crea si se pasó un correo).

#### depends_on
Por ejemplo en: main.tf en s3_website y main.tf en lambdas_api.
Se usó para decirle a Terraform que espere a que un recurso se cree antes de avanzar (por ejemplo, esperar que se configuren los permisos públicos del bucket antes de aplicar la política).

#### lifecycle
Por ejemplo en: main.tf en lambdas_api.
Se usó para evitar que Terraform destruya un recurso antes de crear el nuevo.

lifecycle { 
  create_before_destroy = true 
}

<img width="999" height="1061" alt="AWS_Tripmate drawio (1)" src="https://github.com/user-attachments/assets/ba785eaa-bdad-444d-a48d-d0594094081b" />





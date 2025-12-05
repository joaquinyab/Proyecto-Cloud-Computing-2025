
resource "random_id" "unique" {
  byte_length = 3 # genera 6 caracteres hex
}

locals {
  project_unique       = "${var.project_name}-${random_id.unique.hex}"
  cognito_domain_prefx = "tripmate-${random_id.unique.hex}"
}


provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile == "" ? null : var.aws_profile
}


# Detecta automáticamente el ID de cuenta (sirve para todos los labs)
data "aws_caller_identity" "current" {}


data "aws_iam_role" "labrole" {
  name = "LabRole"
  # Si no existe, Terraform ignora el error (gracias a try())
  count = 1
}

###################################
# FRONTEND RENDER AUTOMÁTICO
###################################
locals {
  api_invoke_url    = module.lambdas_api.api_invoke_url
  frontend_origin   = "http://${module.s3_website.website_hostname}"
  frontend_hostname = module.s3_website.website_hostname


  #----------------------------------------------------------------------------------------------------------------------------------------
  #SI NO FUNCIONA EN OTRA PC BORRAR ESTA LINEA

  lambda_role_final = try("arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole", null)
  #-----------------------------------------------------------------------------------------------------------------------------------------------------------


  # ==== JS que se inyecta dinámicamente ====
  rendered_login_js = <<EOT
  (function(){
    var CD  = "${module.cognito_auth.domain_url}";
    var CID = "${module.lambdas_api.cognito_client_id}";
    var RU  = "${module.lambdas_api.api_invoke_url}/callback";
    var SC  = encodeURIComponent('openid email profile');
    var btn = document.getElementById('login');
    if(btn){
      btn.onclick = function(){
        var url = CD + "/oauth2/authorize?client_id=" + encodeURIComponent(CID) +
                  "&response_type=code&scope=" + SC +
                  "&redirect_uri=" + encodeURIComponent(RU);
        window.location = url;
      };
    }
  })();
  EOT

  rendered_app_js = <<EOT
  (function(){
    window.API_BASE          = "${module.lambdas_api.api_invoke_url}";
    window.COGNITO_DOMAIN    = "${module.cognito_auth.domain_url}";
    window.COGNITO_CLIENT_ID = "${module.lambdas_api.cognito_client_id}";
    window.SIGNOUT_REDIRECT  = "${module.lambdas_api.api_invoke_url}/signout";
  })();
  EOT
}


################
#   VPC + SG   #
################
module "vpc_ext" {
  source  = "./modules/vpc_ext"
  project = local.project_unique
  tags    = var.tags
}

################
#     RDS      #
################
module "rds_mysql" {
  source              = "./modules/rds_mysql"
  project             = local.project_unique
  tags                = var.tags
  subnet_ids          = module.vpc_ext.db_subnet_ids
  vpc_security_groups = [module.vpc_ext.sg_rds_id]

  db_username = var.db_username
  db_password = var.db_password
  db_name     = var.db_name

  multi_az = true
}

#######################################
#             RDS PROXY               #
#######################################

# 1. Guardar credenciales en Secrets Manager (Requisito de RDS Proxy)
resource "aws_secretsmanager_secret" "proxy_db_creds" {
  name        = "${local.project_unique}-db-creds-proxy"
  description = "Credenciales de BD para RDS Proxy"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "proxy_db_creds_val" {
  secret_id = aws_secretsmanager_secret.proxy_db_creds.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
  })
}

# 3. Security Group para el Proxy
resource "aws_security_group" "proxy_sg" {
  name        = "${local.project_unique}-proxy-sg"
  description = "SG para RDS Proxy"
  vpc_id      = module.vpc_ext.vpc_id

  # Entrada: Las Lambdas pueden hablar con el Proxy (puerto 3306)
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.vpc_ext.sg_lambda_id]
    description     = "MySQL desde Lambdas"
  }

  # Salida: El Proxy habla con la RDS
  egress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.vpc_ext.sg_rds_id] # al SG de la RDS
    description     = "Conexion a RDS MySQL"
  }

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # O puedes restringirlo al CIDR de la VPC si usas Endpoints
    description = "HTTPS para Secrets Manager"
  }

  tags = var.tags
}

# 4. Regla extra para el SG de la RDS (Permitir tráfico desde el Proxy)
# Usamos el ID que expone tu módulo vpc_ext
resource "aws_security_group_rule" "allow_proxy_to_rds" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = module.vpc_ext.sg_rds_id
  source_security_group_id = aws_security_group.proxy_sg.id
  description              = "Permitir entrada desde RDS Proxy"
}

# 5. El Recurso RDS Proxy
resource "aws_db_proxy" "main" {
  name                   = "${local.project_unique}-rds-proxy"
  debug_logging          = false
  engine_family          = "MYSQL"
  idle_client_timeout    = 1800
  require_tls            = false
  role_arn               = data.aws_iam_role.labrole[0].arn
  vpc_subnet_ids         = module.vpc_ext.db_subnet_ids # Lo ponemos donde vive la DB
  vpc_security_group_ids = [aws_security_group.proxy_sg.id]

  auth {
    auth_scheme = "SECRETS"
    description = "Autenticacion via Secrets Manager"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.proxy_db_creds.arn
  }

  tags = var.tags
}

# 6. Conectar el Proxy a tu Base de Datos RDS existente
resource "aws_db_proxy_default_target_group" "default" {
  db_proxy_name = aws_db_proxy.main.name
  connection_pool_config {
    connection_borrow_timeout = 120
    max_connections_percent   = 100
  }
}

resource "aws_db_proxy_target" "target" {
  db_proxy_name          = aws_db_proxy.main.name
  target_group_name      = aws_db_proxy_default_target_group.default.name
  db_instance_identifier = module.rds_mysql.id
}

# Politica para permitir que LabRole lea el secret del Proxy
resource "aws_secretsmanager_secret_policy" "proxy_access" {
  secret_arn = aws_secretsmanager_secret.proxy_db_creds.arn

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid       = "AllowLabRoleSecretRead",
      Effect    = "Allow",
      Principal = { AWS = data.aws_iam_role.labrole[0].arn },
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      Resource = aws_secretsmanager_secret.proxy_db_creds.arn
    }]
  })
}

# 1. Esperar 30 segundos despues de que el Proxy esté "listo"
# Esto da tiempo a que los DNS se propaguen y el Proxy acepte conexiones.
resource "time_sleep" "wait_for_proxy" {
  create_duration = "120s"

  depends_on = [
    aws_db_proxy_target.target,
    aws_security_group_rule.allow_proxy_to_rds,
    aws_secretsmanager_secret_policy.proxy_access
  ]
}

# 2. Invocar la Lambda DESPUÉS de la espera
resource "aws_lambda_invocation" "invoke_dbinit" {
  function_name = module.lambdas_api.lambda_dbinit_name
  input         = jsonencode({ action = "init_structure" })

  depends_on = [
    time_sleep.wait_for_proxy # <--- Ahora dependemos del reloj, no solo del proxy
  ]
}

##########################################
#    VPC Enpoint para Secrets Manager    #
##########################################

resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id            = module.vpc_ext.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.secretsmanager" 
  vpc_endpoint_type = "Interface"
  subnet_ids        = module.vpc_ext.db_subnet_ids # Las mismas subnets donde vive el Proxy (DB Subnet)

  security_group_ids = [
    aws_security_group.vpce_sg.id
  ]

  private_dns_enabled = true # Esto es clave para que AWS enrute solo el tráfico
  tags                = var.tags
}

# Security Group para el Endpoint (Necesitas permitir que el Proxy le hable)
resource "aws_security_group" "vpce_sg" {
  name        = "${local.project_unique}-vpce-sg"
  description = "SG para VPC Endpoint de Secrets Manager"
  vpc_id      = module.vpc_ext.vpc_id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.proxy_sg.id] # Permitir entrada desde el Proxy
    description     = "HTTPS desde RDS Proxy"
  }

  tags = var.tags
}

################
#     SNS      #
################
module "sns" {
  source  = "./modules/sns_topic"
  project = local.project_unique
  tags    = var.tags
  email   = var.sns_email_subscription
}

################
#   COGNITO    #
################
module "cognito_auth" {
  source  = "./modules/cognito_auth"
  project = local.project_unique
  tags    = var.tags
  region  = var.aws_region


  domain_prefix = local.cognito_domain_prefx
}

#############################
#  LAMBDAS + API GATEWAY    #
#############################

module "lambdas_api" {
  lambda_role_arn = local.lambda_role_final
  source          = "./modules/lambdas_api"
  project         = local.project_unique
  tags            = var.tags
  region          = var.aws_region
  stage_name      = "prod"

  lambda_subnet_ids = module.vpc_ext.app_subnet_ids
  lambda_sg_id      = module.vpc_ext.sg_lambda_id

  db_host     = aws_db_proxy.main.endpoint
  db_user     = var.db_username
  db_password = var.db_password
  db_name     = var.db_name

  sns_topic_arn = module.sns.topic_arn
  user_pool_id  = module.cognito_auth.user_pool_id
  user_pool_arn = module.cognito_auth.user_pool_arn
  domain_url    = module.cognito_auth.domain_url

  lambda_backend_dir  = "${path.root}/app_code/lambdas/lambda_backend"
  lambda_callback_dir = "${path.root}/app_code/lambdas/lambda_callback"
  lambda_dbinit_dir   = "${path.root}/app_code/lambdas/lambda_dbinit"
  lambda_signout_dir  = "${path.root}/app_code/lambdas/lambda_signout"

  frontend_hostname = module.s3_website.website_hostname
  cors_origin       = "http://${module.s3_website.website_hostname}"
}

################
#     S3       #
################
module "s3_website" {
  source  = "./modules/s3_website"
  project = local.project_unique
  tags    = var.tags
  region  = var.aws_region

  website_bucket_name = var.website_bucket_name

  login_file_path = "${path.root}/app_code/web/login.html"
  app_file_path   = "${path.root}/app_code/web/app.html"

  login_inline_js = local.rendered_login_js
  app_inline_js   = local.rendered_app_js
}

#######################################
#      SNS VPC ENDPOINT (Private)     #
#######################################

# 1. Security Group para permitir tráfico HTTPS hacia el Endpoint
resource "aws_security_group" "sns_vpce_sg" {
  name        = "${local.project_unique}-sns-vpce-sg"
  description = "Permitir trafico HTTPS al endpoint de SNS"
  vpc_id      = module.vpc_ext.vpc_id

  ingress {
    description = "HTTPS desde la VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    # AHORA SÍ funciona esta línea gracias a tu cambio en el output:
    cidr_blocks = [module.vpc_ext.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

# 2. El VPC Endpoint de tipo Interface
resource "aws_vpc_endpoint" "sns" {
  vpc_id            = module.vpc_ext.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.sns"
  vpc_endpoint_type = "Interface"

  # Lo ubicamos en las mismas subnets que las Lambdas
  subnet_ids         = module.vpc_ext.app_subnet_ids
  security_group_ids = [aws_security_group.sns_vpce_sg.id]

  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${local.project_unique}-sns-vpce"
  })
}

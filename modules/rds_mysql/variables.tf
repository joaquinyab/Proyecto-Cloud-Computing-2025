variable "project" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "subnet_ids" {
  type = list(string)
}

variable "vpc_security_groups" {
  type = list(string)
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type = string
}

variable "db_name" {
  type = string
}

variable "multi_az" {
  type    = bool
  default = true
}

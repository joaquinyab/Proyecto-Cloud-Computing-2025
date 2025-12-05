variable "project" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "region" {
  type = string
}

variable "domain_prefix" {
  type = string
}

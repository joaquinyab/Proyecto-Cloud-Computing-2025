variable "project" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "email" {
  type    = string
  default = ""
}

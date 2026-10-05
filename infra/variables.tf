variable "project" {
  description = "Name prefix and Project tag for every resource."
  type        = string
  default     = "kv-cache-demo"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "availability_zone" {
  description = "AZ for the subnet. Change this if g6 capacity is short in one AZ."
  type        = string
  default     = "us-east-1a"
}

variable "instance_type" {
  description = "g6.2xlarge fits the 8 vCPU quota; g6.4xlarge needs 16."
  type        = string
  default     = "g6.2xlarge"
}

variable "root_volume_gb" {
  type    = number
  default = 150
}

variable "state_bucket" {
  description = "Existing bucket that holds Terraform state; results are written under <project>/results/."
  type        = string
}

variable "budget_limit_usd" {
  type    = number
  default = 30
}

variable "alert_email" {
  description = "Where AWS Budgets sends alerts."
  type        = string
}

variable "idle_cpu_percent" {
  description = "Stop the instance when average CPU stays below this for idle_minutes."
  type        = number
  default     = 5
}

variable "idle_minutes" {
  type    = number
  default = 45
}

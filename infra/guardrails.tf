# Backstop only: Budgets data lags by several hours.
# Filters on the Project tag, which must be active as a cost allocation tag.
resource "aws_budgets_budget" "monthly" {
  name         = var.project
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$${var.project}"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# Stops (not terminates) the node when it sits idle.
resource "aws_cloudwatch_metric_alarm" "idle_stop" {
  alarm_name          = "${var.project}-idle-stop"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = aws_instance.node.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = floor(var.idle_minutes / 5)
  comparison_operator = "LessThanThreshold"
  threshold           = var.idle_cpu_percent
  treat_missing_data  = "notBreaching"
  alarm_actions       = ["arn:aws:automate:${var.region}:ec2:stop"]
}

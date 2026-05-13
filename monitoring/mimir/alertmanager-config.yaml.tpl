global:
  resolve_timeout: 5m

route:
  receiver: 'null-default'
  group_by: ['alertname', 'region', 'tenant']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers:
        - severity = critical
      receiver: 'slack-critical'
    - matchers:
        - severity = warning
      receiver: 'slack-warnings'

receivers:
  - name: 'null-default'

  - name: 'slack-critical'
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#alerts-critical'
        send_resolved: true

  - name: 'slack-warnings'
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#alerts-warnings'
        send_resolved: true

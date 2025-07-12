#!/bin/bash

# === CONFIGURATION ===
LOGFILE="/var/log/auth.log" # Use /var/log/secure for Amazon Linux
SNS_TOPIC_ARN="arn:aws:sns:us-east-1:011528264654:ssh-failed"
AWS_CLI="/usr/local/bin/aws" # Change if needed (which aws to verify)
NACL_ID="acl-0b8ae03896defa205" # Your Network ACL ID
FAILURE_THRESHOLD=3 # Number of failed attempts before blocking
BLOCKED_IPS_FILE="/var/log/blocked_ips.log"
REGION="us-east-1" # Enforce region

# Track SSH failures
declare -A SSH_FAILURES
declare -A FIRST_ATTEMPT_TIME

# Function to find the next available rule number
get_next_rule_number() {
 EXISTING_RULES=$($AWS_CLI ec2 describe-network-acls \
 --network-acl-ids "$NACL_ID" \
 --query "NetworkAcls[0].Entries[*].RuleNumber" \
 --region "$REGION" --output text)

 for RULE_NUM in $(seq 100 500); do
 if ! echo "$EXISTING_RULES" | grep -qw "$RULE_NUM"; then
 echo "$RULE_NUM"
 return
 fi
 done
 echo "0" # Return 0 if no rule number is available
}

# Monitor log file for SSH failures
tail -Fn0 "$LOGFILE" | while read line; do
 if echo "$line" | grep -Ei "Failed password|Failed publickey|authentication failure|Connection closed|Connection reset"; then
 IP=$(echo "$line" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")
 
 [[ -z "$IP" ]] && IP="Unknown"
 
 TIMESTAMP=$(date +%s)
 
 # Initialize first attempt time if not already set
 if [[ -z "${FIRST_ATTEMPT_TIME["$IP"]}" ]]; then
 FIRST_ATTEMPT_TIME["$IP"]=$TIMESTAMP
 fi
 
 # Reset if more than 3 minutes (180 seconds) have passed
 if (( TIMESTAMP - FIRST_ATTEMPT_TIME["$IP"] > 180 )); then
 SSH_FAILURES["$IP"]=0
 FIRST_ATTEMPT_TIME["$IP"]=$TIMESTAMP
 fi

 # Increment failure count
 SSH_FAILURES["$IP"]=$(( ${SSH_FAILURES["$IP"]:-0} + 1 ))

 # Log the attempt
 echo "$(date) 🚨 SSH failure detected from $IP (Attempt: ${SSH_FAILURES["$IP"]})" | tee -a /var/log/ssh_monitor.log

 # Send SNS notification for every failed attempt
 MESSAGE="🚨 SSH failure detected from IP: $IP (Attempt: ${SSH_FAILURES["$IP"]}) 🚨"
 $AWS_CLI sns publish --topic-arn "$SNS_TOPIC_ARN" --message "$MESSAGE" --region "$REGION" &>> /var/log/ssh_monitor.log

 # Block IP if threshold exceeded
 if [[ ${SSH_FAILURES["$IP"]} -ge $FAILURE_THRESHOLD ]]; then
 echo "$(date) Blocking IP: $IP in Network ACL..." | tee -a /var/log/ssh_monitor.log
 
 # Get an available rule number
 RULE_NUMBER=$(get_next_rule_number)
 if [[ "$RULE_NUMBER" -eq 0 ]]; then
 echo "$(date) ❌ No available rule numbers left. Unable to block $IP." | tee -a /var/log/ssh_monitor.log
 continue
 fi

 # Try blocking the IP (INGRESS - incoming)
 RESPONSE=$($AWS_CLI ec2 create-network-acl-entry \
 --network-acl-id "$NACL_ID" \
 --rule-number "$RULE_NUMBER" \
 --protocol "6" \
 --rule-action "deny" \
 --cidr-block "$IP/32" \
 --port-range From=22,To=22 \
 --ingress \
 --region "$REGION" 2>&1)

 if [[ $? -eq 0 ]]; then
 echo "$(date) ✅ Successfully blocked $IP with rule number $RULE_NUMBER in Network ACL $NACL_ID" | tee -a "$BLOCKED_IPS_FILE"
 SSH_FAILURES["$IP"]=0 # Reset after blocking
 else
 echo "$(date) ❌ Failed to block $IP: $RESPONSE" | tee -a /var/log/ssh_monitor.log
 fi
 fi
 fi
done
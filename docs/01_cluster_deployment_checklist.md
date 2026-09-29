# AI2050 Cluster - Pre-Deployment Checklist

**Use this checklist BEFORE deploying a new cluster to ensure all prerequisites are in place.**

---

## ✅ Infrastructure Prerequisites (One-Time Setup)

These items persist after cluster deletion and only need to be set up once:

### **1. VPC and Networking** ✅ DONE

- [x] VPC created: `vpc-0f28a5ae1a9eea39f`
- [x] Public subnet: `subnet-006a7368f76fbc413` (for head node)
- [x] Private subnet: `subnet-0157f3ce5e347347c` (for compute nodes)
- [x] Route tables configured
- [x] Security group: `sg-01fecc8fbceb6701b`

**Verification:**
```bash
aws ec2 describe-vpcs --vpc-ids vpc-0f28a5ae1a9eea39f --region eu-north-1
aws ec2 describe-subnets --subnet-ids subnet-006a7368f76fbc413 subnet-0157f3ce5e347347c --region eu-north-1
```

---

### **2. S3 Gateway Endpoint** ✅ DONE

**Purpose:** Allow compute nodes in private subnet to access S3 without internet.

**Check if exists:**
```bash
aws ec2 describe-vpc-endpoints \
  --region eu-north-1 \
  --filters "Name=vpc-id,Values=vpc-0f28a5ae1a9eea39f" "Name=service-name,Values=com.amazonaws.eu-north-1.s3" \
  --query 'VpcEndpoints[0].[VpcEndpointId,State,ServiceName]'
```

**Expected result:**
```
[
    "vpce-05b20a9b65fb1d59e",
    "available",
    "com.amazonaws.eu-north-1.s3"
]
```

**If not exists, create:**
```bash
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-0f28a5ae1a9eea39f \
  --service-name com.amazonaws.eu-north-1.s3 \
  --route-table-ids rtb-09a90438818aa922d rtb-02bbf518780a30dd6 \
  --region eu-north-1
```

---

### **3. DynamoDB Gateway Endpoint** ⚠️ CRITICAL

**Purpose:** Allow compute nodes to retrieve Slurm configuration from DynamoDB.

**Check if exists:**
```bash
aws ec2 describe-vpc-endpoints \
  --region eu-north-1 \
  --filters "Name=vpc-id,Values=vpc-0f28a5ae1a9eea39f" "Name=service-name,Values=com.amazonaws.eu-north-1.dynamodb" \
  --query 'VpcEndpoints[0].[VpcEndpointId,State,ServiceName]'
```

**Expected result:**
```
[
    "vpce-0e782fc7a4052dc89",
    "available",
    "com.amazonaws.eu-north-1.dynamodb"
]
```

**If not exists, create:**
```bash
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-0f28a5ae1a9eea39f \
  --service-name com.amazonaws.eu-north-1.dynamodb \
  --route-table-ids rtb-09a90438818aa922d rtb-02bbf518780a30dd6 \
  --region eu-north-1
```

**Without this, compute nodes will be stuck in CF (Configuring) state!**

---

### **4. Security Group Egress Rules** ⚠️ CRITICAL

**Purpose:** Allow compute nodes to reach S3 and DynamoDB endpoints.

**Check current rules:**
```bash
aws ec2 describe-security-groups \
  --group-ids sg-01fecc8fbceb6701b \
  --region eu-north-1 \
  --query 'SecurityGroups[0].IpPermissionsEgress'
```

**Required rules:**

| Protocol | Port | Destination | Purpose |
|----------|------|-------------|---------|
| All | All | 10.3.0.0/16 | VPC internal traffic |
| TCP | 443 | pl-c3aa4faa | HTTPS to S3 |
| TCP | 443 | pl-adae4bc4 | HTTPS to DynamoDB |

**Check DynamoDB rule specifically:**
```bash
aws ec2 describe-security-groups \
  --group-ids sg-01fecc8fbceb6701b \
  --region eu-north-1 \
  --query 'SecurityGroups[0].IpPermissionsEgress[?PrefixListId==`pl-adae4bc4`]'
```

**If empty (missing DynamoDB rule), add it:**
```bash
aws ec2 authorize-security-group-egress \
  --group-id sg-01fecc8fbceb6701b \
  --region eu-north-1 \
  --ip-permissions "IpProtocol=tcp,FromPort=443,ToPort=443,PrefixListIds=[{PrefixListId=pl-adae4bc4,Description='HTTPS-to-DynamoDB'}]"
```

---

### **5. IAM Service-Linked Role for EC2 Spot** ✅ DONE

**Purpose:** Allow AWS to launch Spot instances.

**Check if exists:**
```bash
aws iam get-role --role-name AWSServiceRoleForEC2Spot --region eu-north-1
```

**Expected result:**
```json
{
    "Role": {
        "RoleName": "AWSServiceRoleForEC2Spot",
        "Arn": "arn:aws:iam::240359167062:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
    }
}
```

**If not found (NoSuchEntity error), create:**
```bash
aws iam create-service-linked-role \
  --aws-service-name spot.amazonaws.com \
  --region eu-north-1
```

**Note:** This is account-wide, only needs to be created once!

---

### **6. SSH Key Pair** ✅ DONE

**Check if exists:**
```bash
aws ec2 describe-key-pairs --key-names ersilia-key --region eu-north-1
```

**Verify you have the private key:**
```bash
ls -lh ~/.ssh/ersilia-key.pem
chmod 400 ~/.ssh/ersilia-key.pem
```

---

## ✅ S3 Bucket Setup

### **7. S3 Bucket Structure**

**Verify bucket exists:**
```bash
aws s3 ls s3://ai2050-ersilia-cluster/ --region eu-north-1
```

**Expected structure:**
```
PRE configs/
PRE input/
PRE output/
PRE packages/
PRE scripts/
PRE sif-files/
```

**Create missing folders:**
```bash
aws s3api put-object --bucket ai2050-ersilia-cluster --key configs/.keep --region eu-north-1
aws s3api put-object --bucket ai2050-ersilia-cluster --key input/.keep --region eu-north-1
aws s3api put-object --bucket ai2050-ersilia-cluster --key output/.keep --region eu-north-1
aws s3api put-object --bucket ai2050-ersilia-cluster --key scripts/.keep --region eu-north-1
aws s3api put-object --bucket ai2050-ersilia-cluster --key sif-files/.keep --region eu-north-1
```

---

### **8. Bootstrap Scripts in S3**

**Upload simplified bootstrap scripts:**

```bash
# Head node bootstrap
aws s3 cp bootstrap-head-simple.sh s3://ai2050-ersilia-cluster/scripts/bootstrap-head-simple.sh --region eu-north-1

# Compute node bootstrap
aws s3 cp bootstrap-compute-simple.sh s3://ai2050-ersilia-cluster/scripts/bootstrap-compute.sh --region eu-north-1

# Verify
aws s3 ls s3://ai2050-ersilia-cluster/scripts/ --region eu-north-1
```

**Expected files:**
```
2026-02-23 XX:XX:XX   1234 bootstrap-compute.sh
2026-02-23 XX:XX:XX   5678 bootstrap-head-simple.sh
```

---

### **9. (Optional) SIF Files in S3**

**Upload pre-built SIF files for faster setup:**

```bash
# Upload individual files
aws s3 cp eos2r5a.sif s3://ai2050-ersilia-cluster/sif-files/ --region eu-north-1

# Or sync entire directory
aws s3 sync ./my-sif-files/ s3://ai2050-ersilia-cluster/sif-files/ --exclude "*" --include "*.sif" --region eu-north-1

# Verify
aws s3 ls s3://ai2050-ersilia-cluster/sif-files/ --region eu-north-1
```

---

### **10. Cluster Configuration File**

**Verify cluster config references correct resources:**

```yaml
# cluster-config-final.yaml

# Check these values:
Region: eu-north-1
HeadNode:
  Networking:
    SubnetId: subnet-006a7368f76fbc413  # Public subnet
  Ssh:
    KeyName: ersilia-key
  CustomActions:
    OnNodeConfigured:
      Script: s3://ai2050-ersilia-cluster/scripts/bootstrap-head-simple.sh

SlurmQueues:
  - Name: test-queue
    Networking:
      SubnetIds:
        - subnet-0157f3ce5e347347c  # Private subnet
      SecurityGroups:
        - sg-01fecc8fbceb6701b  # With DynamoDB egress rule!
    CustomActions:
      OnNodeConfigured:
        Script: s3://ai2050-ersilia-cluster/scripts/bootstrap-compute.sh
```

---

## ✅ Budget and Monitoring

### **11. Budget Alerts** ✅ DONE

**Verify budget exists:**
```bash
aws budgets describe-budgets --account-id 240359167062 --region us-east-1
```

**Expected:** Budget alert at $200/month threshold

---

## 🚀 Ready to Deploy?

### **Pre-Flight Checklist:**

Run these commands to verify everything:

```bash
# 1. VPC endpoints
aws ec2 describe-vpc-endpoints \
  --region eu-north-1 \
  --filters "Name=vpc-id,Values=vpc-0f28a5ae1a9eea39f" \
  --query 'VpcEndpoints[*].[ServiceName,State]'

# Expected: Both S3 and DynamoDB showing "available"

# 2. Security group egress
aws ec2 describe-security-groups \
  --group-ids sg-01fecc8fbceb6701b \
  --region eu-north-1 \
  --query 'SecurityGroups[0].IpPermissionsEgress[*].[IpProtocol,FromPort,PrefixListId]'

# Expected: See pl-adae4bc4 (DynamoDB) in the list

# 3. Service-linked role
aws iam get-role --role-name AWSServiceRoleForEC2Spot 2>&1 | grep -q RoleName && echo "✓ Role exists" || echo "✗ Role missing"

# 4. Bootstrap scripts
aws s3 ls s3://ai2050-ersilia-cluster/scripts/bootstrap-head-simple.sh --region eu-north-1
aws s3 ls s3://ai2050-ersilia-cluster/scripts/bootstrap-compute.sh --region eu-north-1

# 5. SSH key
ls -lh ~/.ssh/ersilia-key.pem
```

**All checks passing?** → Ready to deploy! 🎉

---

## 🎯 Deploy Command

```bash
pcluster create-cluster \
  --cluster-name ai2050-cluster \
  --cluster-configuration cluster-config-final.yaml \
  --region eu-north-1
```

**Expected time:** 5-10 minutes

---

## ⚠️ Common Issues

### **If compute nodes stuck in CF:**
→ Check DynamoDB endpoint and security group rule (items 3 & 4)

### **If cluster creation times out:**
→ Bootstrap script might be too complex (use simplified version)

### **If Spot instances fail:**
→ Check Service-Linked Role (item 5)

---

## 📊 After Deployment

Once cluster shows `CREATE_COMPLETE`:

1. [ ] SSH to head node
2. [ ] Install Python 3.9 (see DEPLOYMENT_GUIDE.md)
3. [ ] Install Apptainer (see DEPLOYMENT_GUIDE.md)
4. [ ] Install ersilia-apptainer
5. [ ] Download SIF files from S3
6. [ ] Submit test job
7. [ ] Verify compute nodes start successfully

---

## 🔄 For Future Deployments

**Good news:** Items 1-6 persist after cluster deletion!

**On next deployment, only need to:**
- [ ] Verify prerequisites still exist (quick check)
- [ ] Upload updated bootstrap scripts (if changed)
- [ ] Deploy cluster
- [ ] Post-bootstrap installation

**Prerequisites do NOT need to be recreated!**

---

## 📝 Notes

- **DynamoDB endpoint:** Created Feb 23, 2026 - `vpce-0e782fc7a4052dc89`
- **S3 endpoint:** Created Feb 7, 2026 - `vpce-05b20a9b65fb1d59e`
- **Service-Linked Role:** Created Feb 23, 2026
- **Security group DynamoDB rule:** Added Feb 23, 2026

**These are permanent infrastructure - don't delete them!**

---

**Last Updated:** February 23, 2026  
**Status:** All prerequisites in place ✅  
**Ready for deployment:** YES
# **CloudCradle**

*Effortless Oracle Cloud Always-Free Tier Deployment*

---

## 🌟 What is CloudCradle?

**CloudCradle** is an out-of-the-box solution for standing up a fully functional Oracle Cloud Infrastructure (OCI) environment — **exclusively using resources from the "Always Free" tier**.

It provides both **Bash** and **Python** implementations to handle the complex setup steps that typically frustrate developers working with OCI.

---

## 💡 Why I Created This

Setting up Oracle Cloud Infrastructure — even for basic usage — involves multiple complex steps:
- Installing and configuring OCI CLI
- Generating API keys and managing authentication
- Fetching region-specific information (availability domains, image OCIDs)
- Creating SSH keys for instance access
- Setting up Terraform variables with correct values

Spinning up an Oracle Cloud account — even just to use the ***Always Free*** tier — can be unnecessarily tedious. 
Between obscure documentation, CLI nuances, Terraform quirks, and OCI's unique design decisions, it's easy to get 
stuck. Eventually we all have to read the 100 pages of outdated documentation and figure it out ourselves through 
trial and error--until now. It's probably why OCI gives you a trial month to do pretty much anything for free, 
otherwise I'm certain I would have triggered billing accidentally and woke up to a mess.

**CloudCradle was born to save others the headache.**
I wanted a setup where:

* You don’t have to bounce between docs and dashboards.
* Everything is **repeatable** and **transparent**.
* You can **learn** from it, not just run it.

This tool automates all of these steps, providing a seamless experience whether you're a cloud beginner or an experienced developer.

---

## 🚀 Features

### Core Capabilities
* ✅ **Dual Implementation**: Both Bash script and Python package
* ✅ **Browser-based Authentication**: No manual API key setup required
* ✅ **Automatic OCI CLI Installation**: Handles Python virtual environments
* ✅ **Dynamic Resource Discovery**: Fetches region-specific Ubuntu images
* ✅ **SSH Key Generation**: Automatic key pair creation
* ✅ **Terraform Integration**: Complete `variables.tf` generation
* ✅ **Session Token Management**: Handles OCI session authentication
* ✅ **Comprehensive Logging**: Rich output with progress indicators

### Infrastructure Support
* ✅ **Always Free Tier Resources**: Optimized for OCI's free tier
* ✅ **Multiple Instance Types**: Support for both x86 and ARM instances
* ✅ **Network Configuration**: VCN, subnets, security groups
* ✅ **Ubuntu Images**: Automatic detection of latest Ubuntu LTS images
* ✅ **Availability Domains**: Dynamic discovery and configuration

---

## 🧠 Project Structure

```bash
oracle-cloud-terraform/
├── src/
│   └── oci_terraform_setup/     # Main Python package
│       ├── __init__.py          # Package initialization
│       ├── __main__.py          # Entry point for CLI execution
│       ├── auth_manager.py      # OCI authentication handling
│       ├── cli.py               # Command-line interface
│       ├── oci_client.py        # OCI SDK client operations
│       ├── setup.py             # Package setup configuration
│       └── terraform_manager.py # Terraform operations and state management
├── ansible/                     # Ansible automation for deployments
│   ├── ansible.cfg             # Ansible configuration
│   ├── data/                   # Deployment data and templates
│   │   └── docker-compose-deployments/
│   ├── playbook.yml            # Main Ansible playbook
│   └── readme.md               # Ansible-specific documentation
├── ssh_keys/                   # Generated SSH key pairs
│   ├── id_rsa                 # Private SSH key
│   └── id_rsa.pub             # Public SSH key
├── main.tf                     # Main Terraform configuration
├── network.tf                  # Network infrastructure (VCN, subnets)
├── instances.tf                # Compute instance definitions
├── variables.tf                # Terraform input variables
├── outputs.tf                  # Terraform output values
├── locals.tf                   # Local variable definitions
├── setup_oci_terraform.sh      # Bash setup script for OCI CLI
├── requirements.txt            # Python dependencies
├── pyproject.toml             # Python project configuration
├── setup.py                   # Package installation script
├── LICENSE                     # Project license
└── README.md                  # Project documentation
```

---


### System Requirements
* **Operating System**: Linux, macOS, potentially Windows through the Python implementation.
* **Python**: 3.8+ (for Python implementation)
* **Terraform**: v1.0+ (will be installed if missing)
* **Oracle Cloud Account**: A fresh Oracle Cloud account signed up through https://signup.oraclecloud.com

---

## 📦 Setup Instructions

```bash
git clone https://github.com/bolabaden/cloudcradle.git
cd cloudcradle
bash scripts/setup_oci_terraform.sh          # Installs and configures OCI CLI, auths through the browser, sets up a python venv
# [SUCCESS] All setup verification checks passed!
# [SUCCESS] ==================== SETUP COMPLETE ====================
# [SUCCESS] OCI Terraform setup completed successfully!
# [INFO] Next steps:
# [INFO]   1. terraform init
# [INFO]   2. terraform plan
# [INFO]   3. terraform apply
# [INFO] 
# [INFO] Files created:
# [INFO]   - ~/.oci/config (OCI CLI configuration with session token)
# [INFO]   - ~/.oci/oci_api_key.pem (Private API key)
# [INFO]   - ~/.oci/oci_api_key_public.pem (Public API key)
# [INFO]   - ./ssh_keys/id_rsa (SSH private key)
# [INFO]   - ./ssh_keys/id_rsa.pub (SSH public key)
# [INFO]   - ./variables.tf (Terraform variables)
# [INFO] =========================================================
```

---

## 🔍 Accessibility Philosophy

CloudCradle emphasizes:

* **Clear logging**: Know what's happening at each step.
* **Descriptive naming**: From variables to resources, it all makes sense.
* **Modular design**: Use just the part you need.
* **Minimal assumptions**: No need to be a Terraform or OCI expert.

---

## 🧩 Use Cases

* 🎓 Learning cloud infra without breaking the bank
* 💻 Hosting a small app or blog for free
* 🧪 Experimenting with VMs, storage, and databases
* 💼 Prototyping side projects with zero upfront cost

---

## 🙌 Contributions & Feedback

Found a bug? Want to suggest a new feature or supported resource?
**Pull requests and issues are welcome!**

This is a growing project aimed at the community — especially those trying to learn or build with **limited time or resources**.

---

## 📛 Name Origin

> “CloudCradle” — because this project gently rocks your Oracle Cloud setup into life, taking care of the heavy lifting, while you rest easy.

---

## 📜 License

MIT License. See [LICENSE](./LICENSE) for details.

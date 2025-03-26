# FedRAMP Quickstart Tools

This directory contains tools to help you deploy, validate, and maintain a FedRAMP-compliant environment on Google Cloud Platform.

## Automation Tools

Located in the `/automation` directory, these tools help automate the deployment and configuration of your FedRAMP environment:

| Tool | Description |
|------|-------------|
| `prerequisites-check.sh` | Verifies that all required prerequisites are installed and configured before deployment |
| `environment-setup.sh` | Prepares your GCP environment by creating folders, enabling APIs, and setting up service accounts |
| `deploy.sh` | Automates the deployment of the entire FedRAMP-aligned architecture |

### Usage

1. Make the scripts executable:
   ```bash
   chmod +x tools/automation/*.sh
   ```

2. Run the prerequisites check:
   ```bash
   ./tools/automation/prerequisites-check.sh
   ```

3. Set up your environment:
   ```bash
   ./tools/automation/environment-setup.sh
   ```

4. Deploy the FedRAMP architecture:
   ```bash
   ./tools/automation/deploy.sh
   ```

## Verification Tools

Located in the `/verification` directory, these tools help validate that your environment meets FedRAMP requirements:

| Tool | Description |
|------|-------------|
| `security-validator.sh` | Checks your environment for security misconfigurations and vulnerabilities |
| `compliance-checker.sh` | Validates your deployment against specific FedRAMP controls |
| `drift-detector.sh` | Detects configuration drift from the secure baseline |

### Usage

1. Make the scripts executable:
   ```bash
   chmod +x tools/verification/*.sh
   ```

2. Validate security configuration:
   ```bash
   ./tools/verification/security-validator.sh
   ```

3. Check FedRAMP compliance:
   ```bash
   ./tools/verification/compliance-checker.sh
   ```

4. Detect configuration drift:
   ```bash
   ./tools/verification/drift-detector.sh
   ```

## Integration with CI/CD

These tools can be integrated into your CI/CD pipeline for automated deployment and validation:

```yaml
# Example GitHub Actions workflow
name: Deploy and Validate FedRAMP Environment

on:
  push:
    branches: [ main ]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Set up Google Cloud SDK
        uses: google-github-actions/setup-gcloud@v1
        with:
          project_id: ${{ secrets.GCP_PROJECT_ID }}
          service_account_key: ${{ secrets.GCP_SA_KEY }}
          
      - name: Deploy FedRAMP Architecture
        run: ./tools/automation/deploy.sh
        
      - name: Validate Security Configuration
        run: ./tools/verification/security-validator.sh
        
      - name: Check FedRAMP Compliance
        run: ./tools/verification/compliance-checker.sh
```

## Customization

All tools are designed to be customizable for your specific environment and requirements. To modify:

1. Review and update the variables at the beginning of each script
2. Add or remove specific checks based on your compliance requirements
3. Extend the scripts with additional validations or deployment steps

## Troubleshooting

If you encounter issues:

1. Check that all prerequisites are installed and properly configured
2. Verify that you have the necessary permissions in your Google Cloud environment
3. Review the script outputs for specific error messages
4. For deployment issues, check the Terraform logs for detailed error information

## Contributing

Contributions to improve these tools are welcome! Please submit pull requests with enhancements, additional validations, or bug fixes.
# GitHub Copilot Instructions for ProxmoxVE

## Overview

This document provides essential guidance for AI coding agents working within the ProxmoxVE codebase. It covers the architecture, critical workflows, conventions, and integration points necessary for effective contributions.

## Architecture

- **Major Components**: The ProxmoxVE project is structured around several key directories:

  - **`ct/`**: Contains scripts for LXC container applications.
  - **`vm/`**: Houses scripts for creating full virtual machines.
  - **`install/`**: Includes installation scripts and templates.
  - **`api/`**: Manages API interactions and configurations.

- **Data Flows**: Understanding how data moves between these components is crucial. For instance, scripts in `ct/` often interact with those in `api/` to manage container states.

## Developer Workflows

- **Setting Up Contributions**: Use the `setup_contrib.sh` script to bootstrap a new contribution project. This script automates the creation of a feature branch and configures the repository for testing.
- **Building and Testing**: Follow the guidelines in `README.md` for building and testing your contributions. Ensure to check the `EXIT_CODES.md` for understanding potential errors during execution.

## Project-Specific Conventions

- **Branching Strategy**: Always create a new feature branch for contributions. The naming convention should reflect the feature or fix being implemented.
- **Script Execution**: Scripts in the `ct/` and `vm/` directories should be executable and follow the standard bash script practices. Ensure to include comments and usage examples in your scripts.

## Integration Points

- **External Dependencies**: The project relies on several external tools and libraries. Refer to the `README.md` in the `install/` directory for a complete list of dependencies.
- **Cross-Component Communication**: Scripts often communicate through defined APIs. Familiarize yourself with the `api/` directory to understand how components interact.

## Examples

- **Creating a New LXC Container**: Refer to the `ct/` directory for examples of scripts that create and manage LXC containers. Each script includes usage examples and expected outputs.
- **VM Provisioning**: The `vm/` directory contains scripts for VM creation, including cloud-init provisioning. Check the `README.md` for detailed instructions on usage.

## Conclusion

This document serves as a starting point for AI coding agents to navigate the ProxmoxVE codebase effectively. For further details, refer to the specific documentation in each directory.

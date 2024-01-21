# Zig-HTMX Chat Application

## Overview

The Zig-HTMX Chat Application is a real-time chat platform that combines the power of Zig for server-side operations with HTMX on the frontend. This application uses WebSockets for seamless, real-time communication between users.

## Features

- **Real-Time Messaging:** Instantly send and receive messages using WebSockets.
- **Zig Backend:** Utilizes the efficiency and safety of Zig programming language.
- **HTMX Frontend:** Dynamic and responsive UI without writing JavaScript.
- **Minimalist Design:** Easy-to-use interface focusing on functionality.

## Prerequisites

Before running the Zig-HTMX Chat Application, ensure you have the following installed:
- Zig (latest version)
- A modern web browser supporting HTMX and WebSockets

## Installation

1. **Clone the Repository**
   ```bash
   git clone https://github.com/hendriknielaender/zig-htmx.git
   cd zig-htmx
   ```
1. **Build the Zig Server(zap)**
   ```bash
   zig build
   ```
1. **Run the server**
   ```bash
   zig-out/bin/zig-htmx
   ```
1. **Access the Application**
   ```bash
   Open your web browser and go to http://localhost:3010.
   ```

# Zig-HTMX Chat Application

## Overview

The Zig-HTMX Chat Application is a real-time chat platform that combines the power of Zig for server-side operations with HTMX on the frontend. The server is built on [Baz](https://github.com/technologylab-ai/baz) and pushes messages to every browser with Server-Sent Events, while messages are sent with a regular HTMX form post.

## Features

- **Real-Time Messaging:** Instantly receive messages using Server-Sent Events. Reconnecting browsers resume from the last message they saw.
- **Zig Backend:** Utilizes the efficiency and safety of Zig programming language.
- **HTMX Frontend:** Dynamic and responsive UI without writing JavaScript.
- **Minimalist Design:** Easy-to-use interface focusing on functionality.

## Prerequisites

Before running the Zig-HTMX Chat Application, ensure you have the following installed:
- Zig 0.17.0 (Baz requires exactly this release)
- A modern web browser supporting HTMX and Server-Sent Events

## Installation

1. **Clone the Repository**
   ```bash
   git clone https://github.com/hendriknielaender/zig-htmx.git
   cd zig-htmx
   ```
1. **Build the Zig Server (Baz)**
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

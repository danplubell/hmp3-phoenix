#hmp3-phoenix
This repository contains a fork of the hmp3-1.5.21 package.

It is a work in progress and YMMV.

This project uses Stack as the build tool.

The autoconf tool is used to generate the configuration header file.

It was tested on OSX Yosemite using GHC-7.10.2

The executable program created by this project is phmp3.

#How to Build
Install mpg321 or mpg123.

Use autoconf to build the configuration program

From the main folder in the project directory do the following:  
    autoconf configure.ac >> configure  
    chmod +x configure  
	./configure  

That will create the config.h file in the src/cbits directory.

Build with the following command:
stack build


	
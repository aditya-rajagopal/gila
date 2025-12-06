# GILA

- VERSION: 0.0.1
- STATUS: DRAFT
- DATE: 2025-12-05

## Abstract

This document describes the GILA specification for a local plain-text task tracking system for developers. It is designed to be 
simple to implement to allow anyone to create tools to read and manage these files in any development environement.
A feature of GILA is that the artifacts are meant to be local and human readable and commitable to remote repositories.

## Introduction

### Motivation

Very often while during development I tend to create tasks within comments for me to come back to later. Often this is disorganized
and it is hard to add more information to them when more information comes along. I often have `TODO` comments littered throughout
my codebase and I dont like it. I also dislike tools like JIRA and Github issues for creating tasks as I usually just want
some place to add information like images, debug logs, and thoughts for me to reference later. Lastly I value being able to 
locally view all my tasks and check them in when I sync my repositories across multiple machines. The aim is to create a 
portable and lightweight specification for creating and managing tasks.

### Scope

GILA is a specification and not a specific tool.

GILA is designed to be
    * Local plain-text: All the artifacts are meant to be local and human readable and commitable to remote repositories.
    * Simple and portable. Anyone should be able to create tools to read and manage these files in any development environement
    * Flexible: Should be extendable in the future when new needs pop up
    * Extensible: Should be able to add new features in the future by anyone

GILA is *NOT* designed to be
    * Generic: It is not meant to be a generic task tracking system without extensions designed for specific needs

The specification gives definitions of the format for the file tree, naming conventions, and the structure of the files.
Additionally there may be suggestions for task generation and parsing tools. Rationale for these will be provided when possible, 
though it is not required.


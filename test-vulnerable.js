import crypto from 'crypto';
import { exec } from 'child_process';
import fs from 'fs';
import path from 'path';

// 1. HARDCODED SECRETS
const apiKey = "sk_live_abc123def456ghi789jkl012mno345";
const password = "SuperSecret123!";
const awsAccessKeyId = "AKIAIOSFODNN7EXAMPLE";
const dbConnectionString = "mongodb://admin:password123@192.168.1.100:27017/mydb";

// 2. SQL INJECTION VULNERABILITIES
const getUserByName = (username) => {
  const query = "SELECT * FROM users WHERE name = '" + username + "'";
  return db.query(query);
};

const updateUser = (id, data) => {
  const query = `UPDATE users SET name = '${data.name}' WHERE id = ${id}`;
  return db.execute(query);
};

// 3. NOSQL INJECTION VULNERABILITIES
const findUser = (req, res) => {
  db.collection('users').find(req.body).toArray();
};

const findOneUser = (req, res) => {
  db.collection('users').findOne(req.query);
};

const deleteUser = (req, res) => {
  db.collection('users').deleteOne(req.params);
};

// 4. HARDCODED IP ADDRESSES
const serverIp = "192.168.1.50";
const apiEndpoint = "http://10.0.0.100:8080/api";
const dbHost = "172.16.0.25:5432";

// 5. INSECURE FUNCTIONS
const runUserCommand = (userInput) => {
  eval(userInput);
};

const executeScript = (script) => {
  exec(script, (error, stdout) => {
    console.log(stdout);
  });
};

const dynamicFunction = new Function('x', 'return x * 2');

// 6. XSS VULNERABILITIES
const renderUserContent = (content) => {
  document.getElementById('output').innerHTML = content;
  document.write(content);
};

const ReactComponent = ({ userHtml }) => {
  return <div dangerouslySetInnerHTML={{ __html: userHtml }} />;
};

// 7. PATH TRAVERSAL VULNERABILITIES
const readUserFile = (req, res) => {
  const filename = req.query.filename;
  fs.readFile(req.body.path, 'utf8', (err, data) => {
    res.send(data);
  });
  
  const filePath = path.join('/uploads', req.params.file);
  const badPath = "../../../etc/passwd";
};

// 8. INSECURE RANDOMNESS
const generateToken = () => {
  return Math.random().toString(36).substring(2);
};

const generateSessionId = () => {
  const token = Math.random() * 1000000;
  return token;
};

// 9. SENSITIVE DATA LOGGING
const loginUser = (username, password) => {
  console.log("Login attempt with password:", password);
  console.log("User token:", token);
  console.log("API Key used:", apikey);
};

// 10. SECURITY TODO/FIXME COMMENTS
// TODO: Fix security vulnerability in authentication
// FIXME: Password is not being hashed properly
// HACK: Bypassing authentication temporarily
// XXX: Security review needed for this section

// 11. WEAK CRYPTOGRAPHY
const hashPassword = (password) => {
  return crypto.createHash('md5').update(password).digest('hex');
};

const weakHash = (data) => {
  return crypto.createHash('sha1').update(data).digest('hex');
};

const encryptData = (data, key) => {
  const cipher = crypto.createCipher('des', key);
  return cipher.update(data, 'utf8', 'hex');
};

// Export for testing
export {
  getUserByName,
  updateUser,
  runUserCommand,
  hashPassword,
  generateToken,
  findUser
};

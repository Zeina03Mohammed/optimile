// Import the functions you need from the SDKs you need
import { initializeApp } from "firebase/app";
import { getAnalytics } from "firebase/analytics";
// TODO: Add SDKs for Firebase products that you want to use
// https://firebase.google.com/docs/web/setup#available-libraries

// Your web app's Firebase configuration
// For Firebase JS SDK v7.20.0 and later, measurementId is optional
const firebaseConfig = {
  apiKey: "AIzaSyDBvFROlsP3Dep8Bwzc2P9KlJcTcAz5YOM",
  authDomain: "optimile-4de76.firebaseapp.com",
  projectId: "optimile-4de76",
  storageBucket: "optimile-4de76.firebasestorage.app",
  messagingSenderId: "107795036305",
  appId: "1:107795036305:web:dd19a5f045386bcb706730",
  measurementId: "G-NZVKSRSCS2"
};

// Initialize Firebase
const app = initializeApp(firebaseConfig);
const analytics = getAnalytics(app);
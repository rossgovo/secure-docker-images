import express from "express";

const app = express();
const port = Number(process.env.PORT ?? 8080);

app.get("/", (_req, res) => res.send("hello world"));

app.listen(port, "0.0.0.0", () => console.log(`listening on ${port}`));
